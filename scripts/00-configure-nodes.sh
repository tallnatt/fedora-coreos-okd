#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_topology

mkdir -p "${WORK_DIR}"
NODES_FILE="${WORK_DIR}/nodes.tsv"
: > "${NODES_FILE}"

if [[ "${USE_RECOMMENDED_DEFAULTS:-0}" == "1" ]]; then
  info "Using recommended VM names, overlay paths, and resource allocations..."
  get_default_nodes > "${NODES_FILE}"
  ok "Node configuration saved to ${NODES_FILE}"
  exit 0
fi

echo ""
echo "============================================================"
echo " Configure VM Names, Overlay Files & Resources"
echo " Press Enter to accept each recommended value."
echo "============================================================"

mapfile -t default_nodes < <(get_default_nodes)
for node_line in "${default_nodes[@]}"; do
  read -r name role ip mac def_vm def_overlay def_vcpu def_ram def_disk <<< "${node_line}"
  echo ""
  echo "--- Node: ${name} (role: ${role}, MAC: ${mac}) ---"

  read -rp "  VM name [recommended: ${def_vm}]: " in_vm
  vm="${in_vm:-${def_vm}}"

  # Update default overlay filename if user changed the VM name
  if [[ "${vm}" != "${def_vm}" ]]; then
    def_overlay="${LIBVIRT_POOL_DIR}/${vm}.qcow2"
  fi
  read -rp "  Overlay file [recommended: ${def_overlay}]: " in_overlay
  overlay="${in_overlay:-${def_overlay}}"

  while true; do
    read -rp "  Disk space in GB [recommended: ${def_disk}]: " in_disk
    disk="${in_disk:-${def_disk}}"
    [[ "${disk}" =~ ^[0-9]+$ ]] && (( disk > 0 )) && break
    echo "  Please enter a positive integer for disk space (GB)."
  done

  while true; do
    read -rp "  vCPU count [recommended: ${def_vcpu}]: " in_vcpu
    vcpu="${in_vcpu:-${def_vcpu}}"
    [[ "${vcpu}" =~ ^[0-9]+$ ]] && (( vcpu > 0 )) && break
    echo "  Please enter a positive integer for vCPU count."
  done

  while true; do
    read -rp "  Memory in MB [recommended: ${def_ram} ($((def_ram / 1024)) GB)]: " in_ram
    ram="${in_ram:-${def_ram}}"
    [[ "${ram}" =~ ^[0-9]+$ ]] && (( ram >= 1024 )) && break
    echo "  Please enter memory in MB (minimum 1024)."
  done

  echo "${name} ${role} ${ip} ${mac} ${vm} ${overlay} ${vcpu} ${ram} ${disk}" >> "${NODES_FILE}"
done

echo ""
ok "Node configuration saved to ${NODES_FILE}"
