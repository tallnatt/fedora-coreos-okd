#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/work"
BIN_DIR="${ROOT_DIR}/bin"
export PATH="${BIN_DIR}:${PATH}"

# Preserve explicit environment overrides before sourcing config files
_ENV_TOPOLOGY="${TOPOLOGY:-}"
_ENV_WORKER_COUNT="${WORKER_COUNT:-}"
_ENV_NETWORK_MODE="${NETWORK_MODE:-}"
_ENV_HOST_BRIDGE="${HOST_BRIDGE:-}"
_ENV_USE_HAPROXY="${USE_HAPROXY:-}"
_ENV_HAPROXY_BIND_IP="${HAPROXY_BIND_IP:-}"

# Load defaults, then user overrides
# shellcheck source=/dev/null
source "${ROOT_DIR}/cluster.env.example"
if [[ -f "${ROOT_DIR}/cluster.env" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/cluster.env"
fi

# Load saved topology & network selections if present
if [[ -f "${WORK_DIR}/.topology.env" ]]; then
  # shellcheck source=/dev/null
  source "${WORK_DIR}/.topology.env"
fi
if [[ -f "${WORK_DIR}/.network.env" ]]; then
  # shellcheck source=/dev/null
  source "${WORK_DIR}/.network.env"
fi

# Restore explicit env overrides
[[ -n "${_ENV_TOPOLOGY}" ]] && TOPOLOGY="${_ENV_TOPOLOGY}"
[[ -n "${_ENV_WORKER_COUNT}" ]] && WORKER_COUNT="${_ENV_WORKER_COUNT}"
[[ -n "${_ENV_NETWORK_MODE}" ]] && NETWORK_MODE="${_ENV_NETWORK_MODE}"
[[ -n "${_ENV_HOST_BRIDGE}" ]] && HOST_BRIDGE="${_ENV_HOST_BRIDGE}"
[[ -n "${_ENV_USE_HAPROXY}" ]] && USE_HAPROXY="${_ENV_USE_HAPROXY}"
[[ -n "${_ENV_HAPROXY_BIND_IP}" ]] && HAPROXY_BIND_IP="${_ENV_HAPROXY_BIND_IP}"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

require_topology() {
  case "${TOPOLOGY:-}" in
    standard|compact|sno) ;;
    *)
      die "TOPOLOGY is not set or invalid ('${TOPOLOGY:-}'). Run 'make select-topology' or set TOPOLOGY=standard|compact|sno."
      ;;
  esac
}

require_network_mode() {
  case "${NETWORK_MODE:-}" in
    nat|bridge) ;;
    *)
      die "NETWORK_MODE is not set or invalid ('${NETWORK_MODE:-}'). Run 'make select-network' or set NETWORK_MODE=nat|bridge."
      ;;
  esac
}

# Prints node records for the selected topology:
#   <name> <role> <ip> <mac> <vm_name> <overlay_path> <vcpu> <ram_mb> <disk_gb>
get_nodes() {
  require_topology
  if [[ -f "${WORK_DIR}/nodes.tsv" ]]; then
    cat "${WORK_DIR}/nodes.tsv"
    return
  fi
  get_default_nodes
}

get_default_nodes() {
  require_topology
  local name vm overlay
  if [[ "${TOPOLOGY}" == "sno" ]]; then
    name="sno-0"
    vm="${CLUSTER_NAME}-${name}"
    overlay="${LIBVIRT_POOL_DIR}/${vm}.qcow2"
    echo "${name} sno ${IP_PREFIX}.11 ${MAC_PREFIX}:11 ${vm} ${overlay} ${SNO_VCPU} ${SNO_RAM_MB} ${SNO_DISK_GB}"
    return
  fi

  # Bootstrap node (temporary)
  name="bootstrap"
  vm="${CLUSTER_NAME}-${name}"
  overlay="${LIBVIRT_POOL_DIR}/${vm}.qcow2"
  echo "${name} bootstrap ${IP_PREFIX}.10 ${MAC_PREFIX}:10 ${vm} ${overlay} ${BOOTSTRAP_VCPU} ${BOOTSTRAP_RAM_MB} ${BOOTSTRAP_DISK_GB}"

  # Control-plane nodes
  local i octet hex_octet
  for ((i = 0; i < MASTER_COUNT; i++)); do
    octet=$((11 + i))
    printf -v hex_octet "%02x" "${octet}"
    name="master-${i}"
    vm="${CLUSTER_NAME}-${name}"
    overlay="${LIBVIRT_POOL_DIR}/${vm}.qcow2"
    echo "${name} master ${IP_PREFIX}.${octet} ${MAC_PREFIX}:${hex_octet} ${vm} ${overlay} ${MASTER_VCPU} ${MASTER_RAM_MB} ${MASTER_DISK_GB}"
  done

  # Worker nodes (if standard topology)
  if [[ "${TOPOLOGY}" == "standard" ]]; then
    for ((i = 0; i < WORKER_COUNT; i++)); do
      octet=$((21 + i))
      printf -v hex_octet "%02x" "${octet}"
      name="worker-${i}"
      vm="${CLUSTER_NAME}-${name}"
      overlay="${LIBVIRT_POOL_DIR}/${vm}.qcow2"
      echo "${name} worker ${IP_PREFIX}.${octet} ${MAC_PREFIX}:${hex_octet} ${vm} ${overlay} ${WORKER_VCPU} ${WORKER_RAM_MB} ${WORKER_DISK_GB}"
    done
  fi
}

vm_name() {
  echo "${CLUSTER_NAME}-$1"
}
