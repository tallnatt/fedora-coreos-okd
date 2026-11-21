#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# By default, rollback performs a full cluster deletion and host restoration.
# destroy.sh sets CLEAN_BASE=0 CLEAN_BIN=0 by default to preserve cached base images/tools.
CLEAN_BASE="${CLEAN_BASE:-1}"
CLEAN_BIN="${CLEAN_BIN:-1}"

if [[ -f "${WORK_DIR}/.rollback.env" ]]; then
  # shellcheck source=/dev/null
  source "${WORK_DIR}/.rollback.env"
fi

info "Rolling back OKD cluster '${CLUSTER_NAME}' and restoring host state..."

# 1. Destroy and undefine VMs listed in work/nodes.tsv
if [[ -f "${WORK_DIR}/nodes.tsv" ]]; then
  while read -r name role ip mac domain overlay_path vcpu ram_mb disk_gb; do
    if command -v virsh >/dev/null 2>&1 && virsh --connect "${LIBVIRT_URI}" dominfo "${domain}" >/dev/null 2>&1; then
      info "Removing VM '${domain}'..."
      virsh --connect "${LIBVIRT_URI}" destroy "${domain}" >/dev/null 2>&1 || true
      virsh --connect "${LIBVIRT_URI}" undefine "${domain}" --remove-all-storage >/dev/null 2>&1 || \
        virsh --connect "${LIBVIRT_URI}" undefine "${domain}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${overlay_path}" && -f "${overlay_path}" ]]; then
      sudo rm -f "${overlay_path}"
    fi
  done < "${WORK_DIR}/nodes.tsv"
fi

# Fallback: destroy any remaining VMs matching cluster prefix
if command -v virsh >/dev/null 2>&1; then
  while read -r domain; do
    [[ -z "${domain}" ]] && continue
    info "Removing VM '${domain}'..."
    virsh --connect "${LIBVIRT_URI}" destroy "${domain}" >/dev/null 2>&1 || true
    virsh --connect "${LIBVIRT_URI}" undefine "${domain}" --remove-all-storage >/dev/null 2>&1 || \
      virsh --connect "${LIBVIRT_URI}" undefine "${domain}" >/dev/null 2>&1 || true
  done < <(virsh --connect "${LIBVIRT_URI}" list --all --name 2>/dev/null | grep "^${CLUSTER_NAME}-" || true)
fi

# 2. Clean up overlays, ISOs, ignition files, and pool directory
if [[ -d "${LIBVIRT_POOL_DIR}" ]]; then
  info "Removing cluster storage artifacts in ${LIBVIRT_POOL_DIR}..."
  sudo rm -f "${LIBVIRT_POOL_DIR}/${CLUSTER_NAME}-"*.qcow2 "${LIBVIRT_POOL_DIR}/${CLUSTER_NAME}.qcow2" "${LIBVIRT_POOL_DIR}/fcos-sno.iso"
  sudo rm -rf "${LIBVIRT_POOL_DIR}/ignition"
  if [[ "${CLEAN_BASE}" == "1" ]]; then
    sudo rm -f "${LIBVIRT_POOL_DIR}/fcos-base.qcow2" "${LIBVIRT_POOL_DIR}/fcos-live.iso"
    sudo rmdir "${LIBVIRT_POOL_DIR}" >/dev/null 2>&1 || true
  fi
fi

# 3. Destroy and undefine libvirt network
if command -v virsh >/dev/null 2>&1 && virsh --connect "${LIBVIRT_URI}" net-info "${NET_NAME}" >/dev/null 2>&1; then
  info "Removing libvirt network '${NET_NAME}'..."
  virsh --connect "${LIBVIRT_URI}" net-destroy "${NET_NAME}" >/dev/null 2>&1 || true
  virsh --connect "${LIBVIRT_URI}" net-undefine "${NET_NAME}" >/dev/null 2>&1 || true
fi

# 4. Restore /etc/hosts
if grep -q "# BEGIN OKD ${CLUSTER_NAME}" /etc/hosts 2>/dev/null; then
  info "Removing OKD entries from /etc/hosts..."
  sudo sed -i "/# BEGIN OKD ${CLUSTER_NAME}/,/# END OKD ${CLUSTER_NAME}/d" /etc/hosts
fi

# 5. Restore HAProxy config and service state
if [[ -f /etc/haproxy/haproxy.cfg.pre-okd ]]; then
  info "Restoring /etc/haproxy/haproxy.cfg from pre-install backup..."
  sudo mv /etc/haproxy/haproxy.cfg.pre-okd /etc/haproxy/haproxy.cfg
fi

if [[ "${HAPROXY_MODIFIED:-false}" == "true" ]]; then
  if [[ "${HAPROXY_WAS_ACTIVE:-false}" == "false" ]]; then
    info "Stopping haproxy (was not running before install)..."
    sudo systemctl stop haproxy >/dev/null 2>&1 || true
  else
    sudo systemctl restart haproxy >/dev/null 2>&1 || true
  fi
  if [[ "${HAPROXY_WAS_ENABLED:-false}" == "false" ]]; then
    sudo systemctl disable haproxy >/dev/null 2>&1 || true
  fi
fi

# 6. Restore firewalld rules added during install
if [[ -n "${FIREWALLD_ADDED_PORTS:-}" ]] && command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  info "Removing firewalld ports added during install (${FIREWALLD_ADDED_PORTS})..."
  for port in ${FIREWALLD_ADDED_PORTS}; do
    sudo firewall-cmd --zone=libvirt --remove-port="${port}" --permanent >/dev/null 2>&1 || true
  done
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 7. Notify about any OS packages installed by 01-check-deps.sh
if [[ -f "${WORK_DIR}/.installed_pkgs" ]]; then
  pkgs=$(tr '\n' ' ' < "${WORK_DIR}/.installed_pkgs")
  warn "Host packages installed during setup: ${pkgs}"
  warn "They were left installed to avoid breaking other workloads; remove manually if unneeded."
fi

# 8. Remove work directory and optionally downloaded binaries
rm -rf "${WORK_DIR}"
if [[ "${CLEAN_BIN}" == "1" && -d "${BIN_DIR}" ]]; then
  info "Removing downloaded CLI tools in ${BIN_DIR}..."
  rm -rf "${BIN_DIR}"
fi

ok "Rollback complete: cluster '${CLUSTER_NAME}' deleted and host restored."
