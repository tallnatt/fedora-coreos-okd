#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/work"
BIN_DIR="${ROOT_DIR}/bin"
export PATH="${BIN_DIR}:${PATH}"

# Preserve explicit environment overrides before sourcing config files
_ENV_TOPOLOGY="${TOPOLOGY:-}"
_ENV_WORKER_COUNT="${WORKER_COUNT:-}"

# Load defaults, then user overrides
# shellcheck source=/dev/null
source "${ROOT_DIR}/cluster.env.example"
if [[ -f "${ROOT_DIR}/cluster.env" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/cluster.env"
fi

# Load saved topology selection if present
if [[ -f "${WORK_DIR}/.topology.env" ]]; then
  # shellcheck source=/dev/null
  source "${WORK_DIR}/.topology.env"
fi

# Restore explicit env overrides
[[ -n "${_ENV_TOPOLOGY}" ]] && TOPOLOGY="${_ENV_TOPOLOGY}"
[[ -n "${_ENV_WORKER_COUNT}" ]] && WORKER_COUNT="${_ENV_WORKER_COUNT}"

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

# Prints node records for the selected topology:
#   <name> <role> <ip> <mac> <vcpu> <ram_mb> <disk_gb>
get_nodes() {
  require_topology
  if [[ "${TOPOLOGY}" == "sno" ]]; then
    echo "sno-0 sno ${IP_PREFIX}.11 ${MAC_PREFIX}:11 ${SNO_VCPU} ${SNO_RAM_MB} ${SNO_DISK_GB}"
    return
  fi

  # Bootstrap node (temporary)
  echo "bootstrap bootstrap ${IP_PREFIX}.10 ${MAC_PREFIX}:10 ${BOOTSTRAP_VCPU} ${BOOTSTRAP_RAM_MB} ${BOOTSTRAP_DISK_GB}"

  # Control-plane nodes
  local i octet hex_octet
  for ((i = 0; i < MASTER_COUNT; i++)); do
    octet=$((11 + i))
    printf -v hex_octet "%02x" "${octet}"
    echo "master-${i} master ${IP_PREFIX}.${octet} ${MAC_PREFIX}:${hex_octet} ${MASTER_VCPU} ${MASTER_RAM_MB} ${MASTER_DISK_GB}"
  done

  # Worker nodes (if standard topology)
  if [[ "${TOPOLOGY}" == "standard" ]]; then
    for ((i = 0; i < WORKER_COUNT; i++)); do
      octet=$((21 + i))
      printf -v hex_octet "%02x" "${octet}"
      echo "worker-${i} worker ${IP_PREFIX}.${octet} ${MAC_PREFIX}:${hex_octet} ${WORKER_VCPU} ${WORKER_RAM_MB} ${WORKER_DISK_GB}"
    done
  fi
}

vm_name() {
  echo "${CLUSTER_NAME}-$1"
}
