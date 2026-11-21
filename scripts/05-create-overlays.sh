#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_topology

BASE_QCOW2="${LIBVIRT_POOL_DIR}/fcos-base.qcow2"
[[ -f "${BASE_QCOW2}" ]] || die "Base FCOS image not found at ${BASE_QCOW2}. Run 'make download' first."

info "Creating qcow2 copy-on-write overlays backed by ${BASE_QCOW2}..."

while read -r name role ip mac vm_name overlay_path vcpu ram_mb disk_gb; do
  sudo mkdir -p "$(dirname "${overlay_path}")"
  if [[ -f "${overlay_path}" ]]; then
    warn "Overlay ${overlay_path} already exists; recreating..."
    sudo rm -f "${overlay_path}"
  fi

  sudo qemu-img create -f qcow2 -F qcow2 -b "${BASE_QCOW2}" "${overlay_path}" "${disk_gb}G" >/dev/null
  sudo chmod 0644 "${overlay_path}"
  ok "Created overlay ${overlay_path} (${disk_gb}G, backing=${BASE_QCOW2})"
done < <(get_nodes)

if command -v restorecon >/dev/null 2>&1; then
  sudo restorecon -Rv "${LIBVIRT_POOL_DIR}" >/dev/null 2>&1 || true
fi
