#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "${WORK_DIR}"

if [[ "${USE_RECOMMENDED_DEFAULTS:-0}" == "1" ]]; then
  info "Using recommended cluster configuration (${CLUSTER_NAME}.${BASE_DOMAIN}, OKD ${OKD_VERSION})..."
else
  echo ""
  echo "============================================================"
  echo " Cluster & General Configuration"
  echo " Press Enter to accept each recommended value."
  echo "============================================================"

  read -rp "  Cluster name [recommended: ${CLUSTER_NAME}]: " in_cluster
  CLUSTER_NAME="${in_cluster:-${CLUSTER_NAME}}"

  read -rp "  Base domain [recommended: ${BASE_DOMAIN}]: " in_domain
  BASE_DOMAIN="${in_domain:-${BASE_DOMAIN}}"

  read -rp "  OKD version [recommended: ${OKD_VERSION}]: " in_okd
  OKD_VERSION="${in_okd:-${OKD_VERSION}}"

  read -rp "  Fedora CoreOS stream [recommended: ${FCOS_STREAM}]: " in_stream
  FCOS_STREAM="${in_stream:-${FCOS_STREAM}}"

  read -rp "  Architecture [recommended: ${ARCH}]: " in_arch
  ARCH="${in_arch:-${ARCH}}"

  read -rp "  SSH public key path [recommended: ${SSH_PUB_KEY_PATH}]: " in_ssh
  SSH_PUB_KEY_PATH="${in_ssh:-${SSH_PUB_KEY_PATH}}"

  read -rp "  Pull secret file path (optional for OKD) [${PULL_SECRET_PATH:-none}]: " in_pull
  if [[ -n "${in_pull}" ]]; then
    PULL_SECRET_PATH="${in_pull}"
  fi

  read -rp "  Libvirt URI [recommended: ${LIBVIRT_URI}]: " in_uri
  LIBVIRT_URI="${in_uri:-${LIBVIRT_URI}}"

  discover_libvirt_pools() {
    local xml pool_name pool_path
    # 1. Inspect libvirt storage pool XML configs in /etc/libvirt/storage/
    if [[ -d /etc/libvirt/storage ]]; then
      for xml in /etc/libvirt/storage/*.xml; do
        [[ -r "${xml}" ]] || continue
        pool_name=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "${xml}" | head -n1)
        pool_path=$(sed -n '/<target>/,/<\/target>/s:.*<path>\(.*\)</path>.*:\1:p' "${xml}" | head -n1)
        if [[ -n "${pool_name}" && -n "${pool_path}" ]]; then
          echo "${pool_name}|${pool_path}"
        fi
      done
    fi

    # 2. Fallback to virsh if /etc/libvirt/storage had no readable dir-backed pools
    if command -v virsh >/dev/null 2>&1; then
      while read -r pool_name; do
        [[ -z "${pool_name}" ]] && continue
        pool_path=$(virsh --connect "${LIBVIRT_URI}" pool-dumpxml "${pool_name}" 2>/dev/null \
          | sed -n '/<target>/,/<\/target>/s:.*<path>\(.*\)</path>.*:\1:p' | head -n1 || true)
        if [[ -n "${pool_path}" ]]; then
          echo "${pool_name}|${pool_path}"
        fi
      done < <(virsh --connect "${LIBVIRT_URI}" pool-list --all --name 2>/dev/null || true)
    fi
  }

  mapfile -t DISCOVERED_POOLS < <(discover_libvirt_pools | awk -F'|' '!seen[$1]++')

  echo ""
  echo "  Libvirt storage pool / image directory:"
  if (( ${#DISCOVERED_POOLS[@]} > 0 )); then
    idx=1
    for entry in "${DISCOVERED_POOLS[@]}"; do
      p_name="${entry%%|*}"
      p_path="${entry#*|}"
      echo "    ${idx}) Pool '${p_name}' (${p_path}/${CLUSTER_NAME})"
      ((idx++))
    done
    custom_idx="${idx}"
    echo "    ${custom_idx}) Custom directory path"

    while true; do
      read -rp "  Select pool/directory [1-${custom_idx}] (default: 1): " pool_choice
      pool_choice="${pool_choice:-1}"
      if [[ "${pool_choice}" =~ ^[0-9]+$ ]] && (( pool_choice >= 1 && pool_choice < custom_idx )); then
        selected="${DISCOVERED_POOLS[$((pool_choice - 1))]}"
        LIBVIRT_POOL_DIR="${selected#*|}/${CLUSTER_NAME}"
        break
      elif [[ "${pool_choice}" == "${custom_idx}" ]]; then
        def_pool="/var/lib/libvirt/images/${CLUSTER_NAME}"
        read -rp "  Custom image/overlay directory [recommended: ${def_pool}]: " in_pool
        LIBVIRT_POOL_DIR="${in_pool:-${def_pool}}"
        break
      else
        echo "  Please enter a number between 1 and ${custom_idx}."
      fi
    done
  else
    def_pool="/var/lib/libvirt/images/${CLUSTER_NAME}"
    read -rp "  No existing pools detected. Image/overlay directory [recommended: ${def_pool}]: " in_pool
    LIBVIRT_POOL_DIR="${in_pool:-${def_pool}}"
  fi
fi

cat > "${WORK_DIR}/.cluster.env" <<EOF
CLUSTER_NAME="${CLUSTER_NAME}"
BASE_DOMAIN="${BASE_DOMAIN}"
OKD_VERSION="${OKD_VERSION}"
FCOS_STREAM="${FCOS_STREAM}"
ARCH="${ARCH}"
SSH_PUB_KEY_PATH="${SSH_PUB_KEY_PATH}"
PULL_SECRET_PATH="${PULL_SECRET_PATH}"
LIBVIRT_URI="${LIBVIRT_URI}"
LIBVIRT_POOL_DIR="${LIBVIRT_POOL_DIR}"
EOF

ok "Cluster configuration saved to ${WORK_DIR}/.cluster.env (${CLUSTER_NAME}.${BASE_DOMAIN})"
