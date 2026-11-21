#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "${WORK_DIR}"

if [[ -n "${NETWORK_MODE:-}" ]]; then
  case "${NETWORK_MODE}" in
    nat)
      USE_HAPROXY="true"
      NET_NAME="${NET_NAME:-${CLUSTER_NAME}-net}"
      info "Using pre-selected network mode: nat (libvirt network '${NET_NAME}' + dnsmasq + HAProxy)"
      ;;
    bridge)
      [[ "${TOPOLOGY:-}" == "sno" ]] && USE_HAPROXY="false"
      info "Using pre-selected network mode: bridge (host bridge '${HOST_BRIDGE}', USE_HAPROXY=${USE_HAPROXY})"
      ;;
    *)
      die "Invalid NETWORK_MODE='${NETWORK_MODE}'. Must be 'nat' or 'bridge'."
      ;;
  esac
else
  echo ""
  echo "============================================================"
  echo " Select Networking Mode"
  echo "============================================================"
  echo "  1) Libvirt NAT + dnsmasq + HAProxy (Recommended)"
  echo "     - Self-contained: creates '${CLUSTER_NAME}-net' (${NET_CIDR}),"
  echo "       DNS/DHCP reservations, and host HAProxy."
  echo "  2) Existing Host Bridge (external DNS/DHCP)"
  echo "     - Attaches VMs to an existing bridge (e.g. br0) on your LAN."
  echo "       Requires external DNS/DHCP (optional host HAProxy)."
  echo ""

  while true; do
    read -rp "Enter choice [1-2] (default: 1): " net_choice
    net_choice="${net_choice:-1}"
    case "${net_choice}" in
      1)
        NETWORK_MODE="nat"
        USE_HAPROXY="true"
        echo ""
        echo "--- Libvirt NAT Network Settings (Enter for recommended) ---"
        def_net_name="${CLUSTER_NAME}-net"
        read -rp "  Libvirt network name [recommended: ${def_net_name}]: " in_net_name
        NET_NAME="${in_net_name:-${def_net_name}}"

        read -rp "  Libvirt bridge interface [recommended: ${NET_BRIDGE}]: " in_net_br
        NET_BRIDGE="${in_net_br:-${NET_BRIDGE}}"

        read -rp "  Network CIDR [recommended: ${NET_CIDR}]: " in_cidr
        NET_CIDR="${in_cidr:-${NET_CIDR}}"

        read -rp "  Gateway IP [recommended: ${NET_GATEWAY}]: " in_gw
        NET_GATEWAY="${in_gw:-${NET_GATEWAY}}"

        read -rp "  Netmask [recommended: ${NET_NETMASK}]: " in_nm
        NET_NETMASK="${in_nm:-${NET_NETMASK}}"

        read -rp "  DHCP range start [recommended: ${NET_DHCP_START}]: " in_ds
        NET_DHCP_START="${in_ds:-${NET_DHCP_START}}"

        read -rp "  DHCP range end [recommended: ${NET_DHCP_END}]: " in_de
        NET_DHCP_END="${in_de:-${NET_DHCP_END}}"

        read -rp "  Node IP prefix [recommended: ${IP_PREFIX}]: " in_ipp
        IP_PREFIX="${in_ipp:-${IP_PREFIX}}"

        read -rp "  Node MAC prefix [recommended: ${MAC_PREFIX}]: " in_macp
        MAC_PREFIX="${in_macp:-${MAC_PREFIX}}"
        break
        ;;
      2)
        NETWORK_MODE="bridge"
        echo ""
        echo "--- Host Bridge Settings ---"
        BRIDGES=()
        if command -v ip >/dev/null 2>&1; then
          mapfile -t BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 || true)
        elif ls -d /sys/class/net/*/bridge >/dev/null 2>&1; then
          for bpath in /sys/class/net/*/bridge; do
            BRIDGES+=("$(basename "$(dirname "${bpath}")")")
          done
        fi

        if (( ${#BRIDGES[@]} > 0 )); then
          echo "  Select a host bridge interface:"
          b_idx=1
          for br in "${BRIDGES[@]}"; do
            br_ip=$(ip -4 addr show dev "${br}" 2>/dev/null | awk '/inet / {print $2}' | head -n1 || true)
            echo "    ${b_idx}) ${br}${br_ip:+ (${br_ip})}"
            ((b_idx++))
          done
          manual_idx="${b_idx}"
          echo "    ${manual_idx}) Enter interface name manually"

          while true; do
            read -rp "  Select bridge [1-${manual_idx}] (default: 1): " br_choice
            br_choice="${br_choice:-1}"
            if [[ "${br_choice}" =~ ^[0-9]+$ ]] && (( br_choice >= 1 && br_choice < manual_idx )); then
              HOST_BRIDGE="${BRIDGES[$((br_choice - 1))]}"
              break
            elif [[ "${br_choice}" == "${manual_idx}" ]]; then
              read -rp "  Host bridge interface name: " br_in
              [[ -n "${br_in}" ]] || { echo "  Bridge name cannot be empty."; continue; }
              HOST_BRIDGE="${br_in}"
              break
            else
              echo "  Please enter a number between 1 and ${manual_idx}."
            fi
          done
        else
          warn "No host bridge interfaces were detected on this system."
          while true; do
            read -rp "  Enter host bridge interface name (or Ctrl+C to abort): " br_in
            if [[ -n "${br_in}" ]]; then
              HOST_BRIDGE="${br_in}"
              break
            fi
          done
        fi

        read -rp "  Node MAC prefix [recommended: ${MAC_PREFIX}]: " in_macp
        MAC_PREFIX="${in_macp:-${MAC_PREFIX}}"

        if [[ "${TOPOLOGY:-}" == "sno" ]]; then
          USE_HAPROXY="false"
        else
          read -rp "  Configure HAProxy on this host for API/Ingress? [Y/n]: " hap_in
          hap_in="${hap_in:-Y}"
          if [[ "${hap_in}" =~ ^[Yy]$ ]]; then
            USE_HAPROXY="true"
            default_ip=$(ip -4 addr show dev "${HOST_BRIDGE}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1 || true)
            read -rp "  Host IP for HAProxy to bind to${default_ip:+ [recommended: ${default_ip}]}: " ip_in
            HAPROXY_BIND_IP="${ip_in:-${default_ip}}"
            [[ -n "${HAPROXY_BIND_IP}" ]] || die "HAPROXY_BIND_IP is required when USE_HAPROXY=true in bridge mode."
          else
            USE_HAPROXY="false"
          fi
        fi
        break
        ;;
      *)
        echo "Please enter 1 or 2."
        ;;
    esac
  done
fi

cat > "${WORK_DIR}/.network.env" <<EOF
NETWORK_MODE="${NETWORK_MODE}"
HOST_BRIDGE="${HOST_BRIDGE}"
USE_HAPROXY="${USE_HAPROXY}"
HAPROXY_BIND_IP="${HAPROXY_BIND_IP}"
NET_NAME="${NET_NAME}"
NET_BRIDGE="${NET_BRIDGE}"
NET_CIDR="${NET_CIDR}"
NET_GATEWAY="${NET_GATEWAY}"
NET_NETMASK="${NET_NETMASK}"
NET_DHCP_START="${NET_DHCP_START}"
NET_DHCP_END="${NET_DHCP_END}"
IP_PREFIX="${IP_PREFIX}"
MAC_PREFIX="${MAC_PREFIX}"
EOF

ok "Network mode saved to ${WORK_DIR}/.network.env: NETWORK_MODE=${NETWORK_MODE}"
