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

  if host_supports_x86_64_v3; then
    ok "Host CPU supports x86-64-v3 (compatible with OKD 5.x and 4.x)."
    latest_okd=$(curl -fsSL --max-time 5 https://api.github.com/repos/okd-project/okd/releases/latest 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null || true)
    [[ -n "${latest_okd}" ]] && OKD_VERSION="${latest_okd}"
  else
    warn "Host CPU does not support x86-64-v3 (x86-64-v2 only). OKD 5.0+ requires x86-64-v3; selecting OKD 4.x."
    OKD_VERSION="${OKD4_FALLBACK_VERSION}"
    latest_okd4=$(curl -fsSL --max-time 5 "https://api.github.com/repos/okd-project/okd/releases?per_page=50" 2>/dev/null \
      | jq -r '[.[] | select(.prerelease == false and (.tag_name | startswith("4.")))][0].tag_name // empty' 2>/dev/null || true)
    [[ -n "${latest_okd4}" ]] && OKD_VERSION="${latest_okd4}"
  fi

  read -rp "  OKD version [recommended: ${OKD_VERSION}]: " in_okd
  OKD_VERSION="${in_okd:-${OKD_VERSION}}"

  read -rp "  Fedora CoreOS stream [recommended: ${FCOS_STREAM}]: " in_stream
  FCOS_STREAM="${in_stream:-${FCOS_STREAM}}"

  read -rp "  Architecture [recommended: ${ARCH}]: " in_arch
  ARCH="${in_arch:-${ARCH}}"

  while true; do
    read -rp "  SSH public key path [recommended: ${SSH_PUB_KEY_PATH}]: " in_ssh
    candidate_ssh="${in_ssh:-${SSH_PUB_KEY_PATH}}"
    # Expand leading ~ if user typed it
    candidate_ssh="${candidate_ssh/#\~/${HOME}}"
    if validate_ssh_pub_key "${candidate_ssh}"; then
      SSH_PUB_KEY_PATH="${candidate_ssh}"
      ok "SSH public key is valid ($(get_ssh_pub_key_fingerprint "${SSH_PUB_KEY_PATH}"))"
      break
    fi
    warn "Invalid or missing SSH public key at '${candidate_ssh}'."
  done

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
        pool_name=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "${xml}" | head -n1 | xargs)
        pool_path=$(sed -n '/<target>/,/<\/target>/s:.*<path>\(.*\)</path>.*:\1:p' "${xml}" | head -n1 | xargs)
        pool_path="${pool_path%/}"
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
          | sed -n '/<target>/,/<\/target>/s:.*<path>\(.*\)</path>.*:\1:p' | head -n1 | xargs || true)
        pool_path="${pool_path%/}"
        if [[ -n "${pool_path}" ]]; then
          echo "${pool_name}|${pool_path}"
        fi
      done < <(virsh --connect "${LIBVIRT_URI}" pool-list --all --name 2>/dev/null || true)
    fi
  }

  select_pool_dir() {
    local label="$1" subdir="$2" default_fallback="$3"
    local idx=1 entry p_name p_path custom_idx choice selected in_dir

    echo "" >&2
    echo "  ${label}:" >&2
    if (( ${#DISCOVERED_POOLS[@]} > 0 )); then
      for entry in "${DISCOVERED_POOLS[@]}"; do
        p_name="${entry%%|*}"
        p_path="${entry#*|}"
        echo "    ${idx}) Pool '${p_name}' (${p_path}/${subdir})" >&2
        ((idx++))
      done
      custom_idx="${idx}"
      echo "    ${custom_idx}) Custom directory path" >&2

      while true; do
        read -rp "  Select pool/directory [1-${custom_idx}] (default: 1): " choice
        choice="${choice:-1}"
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < custom_idx )); then
          selected="${DISCOVERED_POOLS[$((choice - 1))]}"
          echo "${selected#*|}/${subdir}"
          return
        elif [[ "${choice}" == "${custom_idx}" ]]; then
          read -rp "  Custom directory [recommended: ${default_fallback}]: " in_dir
          echo "${in_dir:-${default_fallback}}"
          return
        else
          echo "  Please enter a number between 1 and ${custom_idx}." >&2
        fi
      done
    else
      read -rp "  No existing pools detected. Directory [recommended: ${default_fallback}]: " in_dir
      echo "${in_dir:-${default_fallback}}"
    fi
  }

  mapfile -t DISCOVERED_POOLS < <(discover_libvirt_pools | awk -F'|' '!seen[$1]++')

  LIBVIRT_POOL_DIR="$(select_pool_dir "Libvirt VM overlay pool / directory" "${CLUSTER_NAME}" "/var/lib/libvirt/images/${CLUSTER_NAME}")"
  LIBVIRT_MEDIA_DIR="$(select_pool_dir "Libvirt shared media pool / directory (base FCOS image & ISOs)" "okd-media" "/var/lib/libvirt/images/okd-media")"
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
LIBVIRT_MEDIA_DIR="${LIBVIRT_MEDIA_DIR}"
EOF

ok "Cluster configuration saved to ${WORK_DIR}/.cluster.env (${CLUSTER_NAME}.${BASE_DOMAIN})"
