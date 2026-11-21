#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

info "Checking required host dependencies..."

REQUIRED_CMDS=(virsh virt-install qemu-img haproxy jq curl xz sha256sum)
MISSING=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    MISSING+=("${cmd}")
  fi
done

if (( ${#MISSING[@]} > 0 )); then
  err "Missing required host commands: ${MISSING[*]}"
  echo "Install them on your libvirt host, for example:"
  echo "  Fedora/RHEL: sudo dnf install -y libvirt virt-install qemu-img haproxy jq curl xz"
  echo "  Debian/Ubuntu: sudo apt-get install -y libvirt-clients virtinst qemu-utils haproxy jq curl xz-utils"
  exit 1
fi

if ! virsh --connect "${LIBVIRT_URI}" version >/dev/null 2>&1; then
  die "Cannot connect to libvirt at '${LIBVIRT_URI}'. Ensure libvirtd is running and your user has permission (libvirt group or sudo)."
fi

if [[ ! -f "${SSH_PUB_KEY_PATH}" ]]; then
  die "SSH public key not found at '${SSH_PUB_KEY_PATH}'. Generate one with 'ssh-keygen -t ed25519' or set SSH_PUB_KEY_PATH in cluster.env."
fi

for tool in openshift-install oc butane; do
  if command -v "${tool}" >/dev/null 2>&1; then
    ok "Found ${tool}: $(command -v "${tool}")"
  else
    warn "${tool} not found in PATH — 'make download' will fetch it into ${BIN_DIR}/"
  fi
done

ok "All host prerequisites satisfied."
