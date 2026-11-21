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

  def_pool="/var/lib/libvirt/images/${CLUSTER_NAME}"
  read -rp "  Libvirt image/overlay directory [recommended: ${def_pool}]: " in_pool
  LIBVIRT_POOL_DIR="${in_pool:-${def_pool}}"
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
