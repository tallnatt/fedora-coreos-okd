#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_topology

mkdir -p "${WORK_DIR}"

if [[ "${TOPOLOGY}" == "sno" ]]; then
  VIP_IP="${IP_PREFIX}.11"
else
  VIP_IP="${NET_GATEWAY}"
fi

info "Generating libvirt network XML (${NET_NAME})..."

# Build DNS host entries and DHCP static reservations from topology nodes
DNS_HOSTS_XML=""
DHCP_HOSTS_XML=""
while read -r name role ip mac vcpu ram_mb disk_gb; do
  DNS_HOSTS_XML+="    <host ip='${ip}'>
      <hostname>${name}.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>${name}</hostname>
    </host>
"
  DHCP_HOSTS_XML+="      <host mac='${mac}' name='${name}' ip='${ip}'/>
"
done < <(get_nodes)

cat > "${WORK_DIR}/network.xml" <<EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${NET_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${NET_BRIDGE}' stp='on' delay='0'/>
  <domain name='${CLUSTER_NAME}.${BASE_DOMAIN}' localOnly='yes'/>
  <dns>
    <host ip='${VIP_IP}'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
${DNS_HOSTS_XML}  </dns>
  <ip address='${NET_GATEWAY}' netmask='${NET_NETMASK}'>
    <dhcp>
      <range start='${NET_DHCP_START}' end='${NET_DHCP_END}'/>
${DHCP_HOSTS_XML}    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${VIP_IP}'/>
  </dnsmasq:options>
</network>
EOF

# Recreate or start libvirt network
if virsh --connect "${LIBVIRT_URI}" net-info "${NET_NAME}" >/dev/null 2>&1; then
  info "Updating existing libvirt network '${NET_NAME}'..."
  virsh --connect "${LIBVIRT_URI}" net-destroy "${NET_NAME}" >/dev/null 2>&1 || true
  virsh --connect "${LIBVIRT_URI}" net-undefine "${NET_NAME}" >/dev/null 2>&1 || true
fi

virsh --connect "${LIBVIRT_URI}" net-define "${WORK_DIR}/network.xml"
virsh --connect "${LIBVIRT_URI}" net-autostart "${NET_NAME}"
virsh --connect "${LIBVIRT_URI}" net-start "${NET_NAME}"
ok "Libvirt network '${NET_NAME}' is active on bridge '${NET_BRIDGE}' (${NET_GATEWAY})."

# Ensure the libvirt host itself can resolve API & console URLs
info "Updating /etc/hosts for host-side API/console resolution..."
sudo sed -i "/# BEGIN OKD ${CLUSTER_NAME}/,/# END OKD ${CLUSTER_NAME}/d" /etc/hosts
{
  echo "# BEGIN OKD ${CLUSTER_NAME}"
  echo "${VIP_IP} api.${CLUSTER_NAME}.${BASE_DOMAIN} api-int.${CLUSTER_NAME}.${BASE_DOMAIN} console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN} oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
  echo "# END OKD ${CLUSTER_NAME}"
} | sudo tee -a /etc/hosts >/dev/null

# Configure HAProxy for multi-node topologies (Standard HA / Compact 3-node)
if [[ "${TOPOLOGY}" != "sno" ]]; then
  info "Configuring HAProxy on ${NET_GATEWAY} for API (6443), MCS (22623), and Ingress (80/443)..."
  if [[ -f /etc/haproxy/haproxy.cfg && ! -f /etc/haproxy/haproxy.cfg.pre-okd ]]; then
    sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.pre-okd
  fi

  API_SERVERS=""
  MCS_SERVERS=""
  INGRESS_HTTP_SERVERS=""
  INGRESS_HTTPS_SERVERS=""

  while read -r name role ip mac vcpu ram_mb disk_gb; do
    if [[ "${role}" == "bootstrap" || "${role}" == "master" ]]; then
      API_SERVERS+="    server ${name} ${ip}:6443 check
"
      MCS_SERVERS+="    server ${name} ${ip}:22623 check
"
    fi
    if [[ "${TOPOLOGY}" == "standard" && "${role}" == "worker" ]] || \
       [[ "${TOPOLOGY}" == "compact" && "${role}" == "master" ]]; then
      INGRESS_HTTP_SERVERS+="    server ${name} ${ip}:80 check
"
      INGRESS_HTTPS_SERVERS+="    server ${name} ${ip}:443 check
"
    fi
  done < <(get_nodes)

  cat > "${WORK_DIR}/haproxy.cfg" <<EOF
global
    log /dev/log local0
    maxconn 4096
    daemon

defaults
    mode tcp
    log global
    option tcplog
    option dontlognull
    retries 3
    timeout connect 5s
    timeout client 60s
    timeout server 60s

frontend okd_api_fe
    bind ${HAPROXY_BIND_IP}:6443
    default_backend okd_api_be

backend okd_api_be
    balance roundrobin
${API_SERVERS}
frontend okd_mcs_fe
    bind ${HAPROXY_BIND_IP}:22623
    default_backend okd_mcs_be

backend okd_mcs_be
    balance roundrobin
${MCS_SERVERS}
frontend okd_ingress_http_fe
    bind ${HAPROXY_BIND_IP}:80
    default_backend okd_ingress_http_be

backend okd_ingress_http_be
    balance roundrobin
${INGRESS_HTTP_SERVERS}
frontend okd_ingress_https_fe
    bind ${HAPROXY_BIND_IP}:443
    default_backend okd_ingress_https_be

backend okd_ingress_https_be
    balance roundrobin
${INGRESS_HTTPS_SERVERS}
EOF

  sudo cp "${WORK_DIR}/haproxy.cfg" /etc/haproxy/haproxy.cfg
  # Allow HAProxy to bind to the libvirt bridge IP on SELinux-enabled hosts
  if command -v setsebool >/dev/null 2>&1; then
    sudo setsebool -P haproxy_connect_any 1 >/dev/null 2>&1 || true
  fi
  sudo systemctl enable --now haproxy
  sudo systemctl restart haproxy
  ok "HAProxy configured and running on ${HAPROXY_BIND_IP}."
fi

# Open firewalld ports if firewalld is active
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  info "Configuring firewalld rules for libvirt zone..."
  for port in 6443/tcp 22623/tcp 80/tcp 443/tcp 53/udp 53/tcp; do
    sudo firewall-cmd --zone=libvirt --add-port="${port}" --permanent >/dev/null 2>&1 || true
  done
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
fi
