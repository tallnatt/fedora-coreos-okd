#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_topology
require_network_mode

if [[ "${NETWORK_MODE}" == "bridge" ]]; then
  NET_ARG_BASE="bridge=${HOST_BRIDGE}"
else
  NET_ARG_BASE="network=${NET_NAME}"
fi

# Pick best available os-variant
OS_VARIANT="fedora-unknown"
if command -v osinfo-query >/dev/null 2>&1; then
  if osinfo-query os --fields=short-id 2>/dev/null | grep -qx "fedora-coreos-stable"; then
    OS_VARIANT="fedora-coreos-stable"
  fi
fi

info "Provisioning libvirt VMs (os-variant=${OS_VARIANT}, network=${NET_ARG_BASE})..."

while read -r name role ip mac domain overlay vcpu ram_mb disk_gb; do
  ign_path="${LIBVIRT_POOL_DIR}/ignition/${name}.ign"

  [[ -f "${overlay}" ]] || die "Overlay not found: ${overlay}. Run 'make overlays' first."
  [[ -f "${ign_path}" ]] || die "Ignition file not found: ${ign_path}. Run 'make ignition' first."

  if virsh --connect "${LIBVIRT_URI}" dominfo "${domain}" >/dev/null 2>&1; then
    warn "VM '${domain}' already exists; skipping creation."
    continue
  fi

  if [[ "${TOPOLOGY}" == "sno" ]]; then
    SNO_ISO="${LIBVIRT_POOL_DIR}/fcos-sno.iso"
    [[ -f "${SNO_ISO}" ]] || die "SNO ISO not found: ${SNO_ISO}"
    info "Creating SNO VM '${domain}' (${vcpu} vCPU, ${ram_mb} MB RAM, ${disk_gb}G overlay)..."
    virt-install \
      --connect "${LIBVIRT_URI}" \
      --name "${domain}" \
      --vcpus "${vcpu}" \
      --memory "${ram_mb}" \
      --disk "path=${overlay},format=qcow2,bus=virtio" \
      --cdrom "${SNO_ISO}" \
      --boot hd,cdrom \
      --network "${NET_ARG_BASE},mac=${mac},model=virtio" \
      --os-variant "${OS_VARIANT}" \
      --graphics vnc,listen=0.0.0.0 \
      --console pty,target_type=serial \
      --noautoconsole
  else
    info "Creating VM '${domain}' (${role}, ${ip}, ${vcpu} vCPU, ${ram_mb} MB RAM, ${disk_gb}G overlay)..."
    virt-install \
      --connect "${LIBVIRT_URI}" \
      --name "${domain}" \
      --vcpus "${vcpu}" \
      --memory "${ram_mb}" \
      --disk "path=${overlay},format=qcow2,bus=virtio" \
      --network "${NET_ARG_BASE},mac=${mac},model=virtio" \
      --os-variant "${OS_VARIANT}" \
      --import \
      --graphics vnc,listen=0.0.0.0 \
      --console pty,target_type=serial \
      --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${ign_path}" \
      --noautoconsole
  fi

  ok "Provisioned and started '${domain}'"
done < <(get_nodes)
