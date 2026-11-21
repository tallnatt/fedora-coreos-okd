#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

info "Destroying OKD cluster '${CLUSTER_NAME}' resources..."

# Destroy and undefine VMs listed in nodes.tsv (handles custom VM names/overlays)
if [[ -f "${WORK_DIR}/nodes.tsv" ]]; then
  while read -r name role ip mac domain overlay_path vcpu ram_mb disk_gb; do
    if virsh --connect "${LIBVIRT_URI}" dominfo "${domain}" >/dev/null 2>&1; then
      info "Removing VM '${domain}'..."
      virsh --connect "${LIBVIRT_URI}" destroy "${domain}" >/dev/null 2>&1 || true
      virsh --connect "${LIBVIRT_URI}" undefine "${domain}" --remove-all-storage >/dev/null 2>&1 || \
        virsh --connect "${LIBVIRT_URI}" undefine "${domain}" >/dev/null 2>&1 || true
    fi
    [[ -n "${overlay_path}" && -f "${overlay_path}" ]] && sudo rm -f "${overlay_path}"
  done < "${WORK_DIR}/nodes.tsv"
fi

# Fallback: destroy any remaining VMs matching cluster prefix
while read -r domain; do
  [[ -z "${domain}" ]] && continue
  info "Removing VM '${domain}'..."
  virsh --connect "${LIBVIRT_URI}" destroy "${domain}" >/dev/null 2>&1 || true
  virsh --connect "${LIBVIRT_URI}" undefine "${domain}" --remove-all-storage >/dev/null 2>&1 || \
    virsh --connect "${LIBVIRT_URI}" undefine "${domain}" >/dev/null 2>&1 || true
done < <(virsh --connect "${LIBVIRT_URI}" list --all --name | grep "^${CLUSTER_NAME}-" || true)

# Clean up overlays and ignition files (preserve fcos-base.qcow2 unless CLEAN_BASE=1)
if [[ -d "${LIBVIRT_POOL_DIR}" ]]; then
  info "Removing qcow2 overlays and Ignition files in ${LIBVIRT_POOL_DIR}..."
  sudo rm -f "${LIBVIRT_POOL_DIR}/${CLUSTER_NAME}-"*.qcow2 "${LIBVIRT_POOL_DIR}/fcos-sno.iso"
  sudo rm -rf "${LIBVIRT_POOL_DIR}/ignition"
  if [[ "${CLEAN_BASE:-0}" == "1" ]]; then
    sudo rm -f "${LIBVIRT_POOL_DIR}/fcos-base.qcow2" "${LIBVIRT_POOL_DIR}/fcos-live.iso"
  fi
fi

# Destroy and undefine libvirt network
if virsh --connect "${LIBVIRT_URI}" net-info "${NET_NAME}" >/dev/null 2>&1; then
  info "Removing libvirt network '${NET_NAME}'..."
  virsh --connect "${LIBVIRT_URI}" net-destroy "${NET_NAME}" >/dev/null 2>&1 || true
  virsh --connect "${LIBVIRT_URI}" net-undefine "${NET_NAME}" >/dev/null 2>&1 || true
fi

# Clean /etc/hosts entries
if grep -q "# BEGIN OKD ${CLUSTER_NAME}" /etc/hosts 2>/dev/null; then
  info "Removing OKD entries from /etc/hosts..."
  sudo sed -i "/# BEGIN OKD ${CLUSTER_NAME}/,/# END OKD ${CLUSTER_NAME}/d" /etc/hosts
fi

# Restore HAProxy config if backup exists
if [[ -f /etc/haproxy/haproxy.cfg.pre-okd ]]; then
  info "Restoring /etc/haproxy/haproxy.cfg from backup..."
  sudo mv /etc/haproxy/haproxy.cfg.pre-okd /etc/haproxy/haproxy.cfg
  sudo systemctl restart haproxy >/dev/null 2>&1 || true
fi

rm -rf "${WORK_DIR}"
ok "Cluster '${CLUSTER_NAME}' destroyed."
