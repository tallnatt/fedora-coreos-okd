#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

info "Checking required host dependencies..."

REQUIRED_CMDS=(virsh virt-install qemu-img haproxy jq curl xz sha256sum)
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    MISSING_CMDS+=("${cmd}")
  fi
done

detect_pkg_manager() {
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "apt-get"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  else
    echo ""
  fi
}

map_cmd_to_pkg() {
  local pm="$1" cmd="$2"
  case "${pm}:${cmd}" in
    dnf:virsh|yum:virsh)            echo "libvirt-client" ;;
    dnf:virt-install|yum:virt-install) echo "virt-install" ;;
    dnf:qemu-img|yum:qemu-img)      echo "qemu-img" ;;
    dnf:sha256sum|yum:sha256sum)    echo "coreutils" ;;
    dnf:*|yum:*)                    echo "${cmd}" ;;

    apt-get:virsh)                  echo "libvirt-clients" ;;
    apt-get:virt-install)           echo "virtinst" ;;
    apt-get:qemu-img)               echo "qemu-utils" ;;
    apt-get:xz)                     echo "xz-utils" ;;
    apt-get:sha256sum)              echo "coreutils" ;;
    apt-get:*)                      echo "${cmd}" ;;

    zypper:virsh)                   echo "libvirt-client" ;;
    zypper:virt-install)            echo "virt-install" ;;
    zypper:qemu-img)                echo "qemu-tools" ;;
    zypper:sha256sum)               echo "coreutils" ;;
    zypper:*)                       echo "${cmd}" ;;

    pacman:virsh)                   echo "libvirt" ;;
    pacman:virt-install)            echo "virt-install" ;;
    pacman:qemu-img)                echo "qemu-base" ;;
    pacman:sha256sum)               echo "coreutils" ;;
    pacman:*)                       echo "${cmd}" ;;
  esac
}

if (( ${#MISSING_CMDS[@]} > 0 )); then
  PKG_MGR="$(detect_pkg_manager)"
  warn "Missing required host commands: ${MISSING_CMDS[*]}"

  if [[ -z "${PKG_MGR}" ]]; then
    die "Could not detect a supported package manager (dnf, yum, apt-get, zypper, pacman). Please install: ${MISSING_CMDS[*]}"
  fi

  MISSING_PKGS=()
  for cmd in "${MISSING_CMDS[@]}"; do
    pkg="$(map_cmd_to_pkg "${PKG_MGR}" "${cmd}")"
    if [[ ! " ${MISSING_PKGS[*]} " =~ " ${pkg} " ]]; then
      MISSING_PKGS+=("${pkg}")
    fi
  done

  echo ""
  echo "Detected package manager : ${PKG_MGR}"
  echo "Missing packages         : ${MISSING_PKGS[*]}"
  echo ""

  if [[ "${AUTO_INSTALL_DEPS:-0}" == "1" ]]; then
    ans="Y"
  else
    read -rp "Proceed with installing these packages using ${PKG_MGR}? [Y/n]: " ans
    ans="${ans:-Y}"
  fi

  if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
    die "Aborted by user. Install the missing packages (${MISSING_PKGS[*]}) and re-run."
  fi

  info "Installing missing packages via ${PKG_MGR}..."
  case "${PKG_MGR}" in
    dnf|yum)
      sudo "${PKG_MGR}" install -y "${MISSING_PKGS[@]}"
      ;;
    apt-get)
      sudo apt-get update
      sudo apt-get install -y "${MISSING_PKGS[@]}"
      ;;
    zypper)
      sudo zypper --non-interactive install "${MISSING_PKGS[@]}"
      ;;
    pacman)
      sudo pacman -Sy --noconfirm "${MISSING_PKGS[@]}"
      ;;
  esac

  mkdir -p "${WORK_DIR}"
  printf '%s\n' "${MISSING_PKGS[@]}" > "${WORK_DIR}/.installed_pkgs"

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now libvirtd >/dev/null 2>&1 || true
  fi
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
