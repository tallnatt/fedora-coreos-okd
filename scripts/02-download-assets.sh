#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_topology

mkdir -p "${BIN_DIR}" "${WORK_DIR}/downloads"
sudo mkdir -p "${LIBVIRT_POOL_DIR}"

# 1. Download openshift-install and oc if missing
if [[ "${OKD_VERSION}" == 5.* ]] && ! host_supports_x86_64_v3; then
  warn "OKD ${OKD_VERSION} requires x86-64-v3 CPU instructions, which this host does not appear to support (use OKD 4.x such as ${OKD4_FALLBACK_VERSION})."
fi
if ! command -v openshift-install >/dev/null 2>&1 || ! command -v oc >/dev/null 2>&1; then
  info "Downloading OKD ${OKD_VERSION} installer and client tools..."
  case "${ARCH}" in
    x86_64|amd64) OKD_ARCH_SUFFIX="" ;;
    aarch64|arm64) OKD_ARCH_SUFFIX="-arm64" ;;
    *) OKD_ARCH_SUFFIX="-${ARCH}" ;;
  esac
  INST_TGZ="${WORK_DIR}/downloads/openshift-install-linux${OKD_ARCH_SUFFIX}-${OKD_VERSION}.tar.gz"
  CLI_TGZ="${WORK_DIR}/downloads/openshift-client-linux${OKD_ARCH_SUFFIX}-${OKD_VERSION}.tar.gz"
  BASE_URL="https://github.com/okd-project/okd/releases/download/${OKD_VERSION}"

  if [[ ! -f "${INST_TGZ}" ]]; then
    curl -fSL "${BASE_URL}/openshift-install-linux${OKD_ARCH_SUFFIX}-${OKD_VERSION}.tar.gz" -o "${INST_TGZ}" \
      || die "Failed to download openshift-install for OKD '${OKD_VERSION}'. Verify the tag at https://github.com/okd-project/okd/releases"
  fi
  if [[ ! -f "${CLI_TGZ}" ]]; then
    curl -fSL "${BASE_URL}/openshift-client-linux${OKD_ARCH_SUFFIX}-${OKD_VERSION}.tar.gz" -o "${CLI_TGZ}" \
      || die "Failed to download oc client for OKD '${OKD_VERSION}'. Verify the tag at https://github.com/okd-project/okd/releases"
  fi

  tar -xzf "${INST_TGZ}" -C "${BIN_DIR}" openshift-install
  tar -xzf "${CLI_TGZ}" -C "${BIN_DIR}" oc kubectl
  chmod +x "${BIN_DIR}/openshift-install" "${BIN_DIR}/oc" "${BIN_DIR}/kubectl"
  ok "Installed openshift-install and oc into ${BIN_DIR}"
fi

# 2. Download butane if missing
if ! command -v butane >/dev/null 2>&1; then
  info "Downloading butane..."
  BUTANE_ARCH="${ARCH}"
  curl -fSL "https://github.com/coreos/butane/releases/latest/download/butane-${BUTANE_ARCH}-unknown-linux-gnu" \
    -o "${BIN_DIR}/butane"
  chmod +x "${BIN_DIR}/butane"
  ok "Installed butane into ${BIN_DIR}/butane"
fi

# 3. Fetch CoreOS stream metadata (prefer openshift-install's matched stream)
STREAM_JSON="${WORK_DIR}/downloads/coreos-stream.json"
if openshift-install coreos print-stream-json > "${STREAM_JSON}" 2>/dev/null && jq -e '.architectures' "${STREAM_JSON}" >/dev/null 2>&1; then
  ok "Using CoreOS stream metadata from openshift-install (${OKD_VERSION})"
else
  info "Fetching Fedora CoreOS '${FCOS_STREAM}' stream metadata..."
  curl -fsSL "https://builds.coreos.fedoraproject.org/streams/${FCOS_STREAM}.json" -o "${STREAM_JSON}"
fi

# 4. Download and decompress CoreOS base qcow2 image (used as backing file for node overlays)
BASE_QCOW2="${LIBVIRT_MEDIA_DIR}/fcos-base.qcow2"
if [[ ! -f "${BASE_QCOW2}" ]]; then
  QCOW_FMT=""
  QCOW_URL=""
  QCOW_SHA=""
  for fmt in "qcow2.xz" "qcow2.gz" "qcow2"; do
    url=$(jq -r ".architectures.${ARCH}.artifacts.qemu.formats[\"${fmt}\"].disk.location // empty" "${STREAM_JSON}")
    if [[ -n "${url}" ]]; then
      QCOW_FMT="${fmt}"
      QCOW_URL="${url}"
      QCOW_SHA=$(jq -r ".architectures.${ARCH}.artifacts.qemu.formats[\"${fmt}\"].disk.sha256 // empty" "${STREAM_JSON}")
      break
    fi
  done

  # If openshift-install stream metadata doesn't include qemu qcow2, fall back to FCOS stream
  if [[ -z "${QCOW_URL}" ]]; then
    warn "No qemu qcow2 artifact in ${OKD_VERSION} stream; falling back to Fedora CoreOS '${FCOS_STREAM}' qcow2..."
    FCOS_JSON="${WORK_DIR}/downloads/fcos-${FCOS_STREAM}.json"
    curl -fsSL "https://builds.coreos.fedoraproject.org/streams/${FCOS_STREAM}.json" -o "${FCOS_JSON}"
    QCOW_FMT="qcow2.xz"
    QCOW_URL=$(jq -r ".architectures.${ARCH}.artifacts.qemu.formats[\"qcow2.xz\"].disk.location // empty" "${FCOS_JSON}")
    QCOW_SHA=$(jq -r ".architectures.${ARCH}.artifacts.qemu.formats[\"qcow2.xz\"].disk.sha256 // empty" "${FCOS_JSON}")
  fi

  [[ -n "${QCOW_URL}" ]] || die "Could not find CoreOS qcow2 URL for ${ARCH}"

  QCOW_DL="${WORK_DIR}/downloads/fcos-base.${QCOW_FMT}"
  info "Downloading CoreOS QEMU base image (${QCOW_FMT})..."
  curl -fSL "${QCOW_URL}" -o "${QCOW_DL}"

  [[ -n "${QCOW_SHA}" ]] && echo "${QCOW_SHA}  ${QCOW_DL}" | sha256sum -c -
  info "Preparing CoreOS base image at ${BASE_QCOW2}..."
  sudo mkdir -p "$(dirname "${BASE_QCOW2}")"
  case "${QCOW_FMT}" in
    qcow2.xz) xz -dc "${QCOW_DL}" | sudo tee "${BASE_QCOW2}" >/dev/null ;;
    qcow2.gz) gzip -dc "${QCOW_DL}" | sudo tee "${BASE_QCOW2}" >/dev/null ;;
    qcow2)    sudo cp "${QCOW_DL}" "${BASE_QCOW2}" ;;
  esac
  sudo chmod 0644 "${BASE_QCOW2}"
  ok "CoreOS base image ready at ${BASE_QCOW2}"
else
  ok "CoreOS base image already exists at ${BASE_QCOW2}"
fi

# 5. For SNO, also download FCOS live ISO and coreos-installer
if [[ "${TOPOLOGY}" == "sno" ]]; then
  if ! command -v coreos-installer >/dev/null 2>&1; then
    info "Downloading coreos-installer for SNO live ISO embedding..."
    # Use fedora coreos-installer container or binary release if available
    CI_URL=$(curl -fsSL https://api.github.com/repos/coreos/coreos-installer/releases/latest \
      | jq -r ".assets[] | select(.name | test(\"coreos-installer-${ARCH}-unknown-linux-gnu$\")) | .browser_download_url" | head -n1 || true)
    if [[ -n "${CI_URL}" && "${CI_URL}" != "null" ]]; then
      curl -fSL "${CI_URL}" -o "${BIN_DIR}/coreos-installer"
      chmod +x "${BIN_DIR}/coreos-installer"
    else
      warn "Could not download coreos-installer binary; will use podman/docker quay.io/coreos/coreos-installer if available."
    fi
  fi

  LIVE_ISO="${LIBVIRT_MEDIA_DIR}/fcos-live.iso"
  if [[ ! -f "${LIVE_ISO}" ]]; then
    ISO_URL=$(jq -r ".architectures.${ARCH}.artifacts.metal.formats.iso.disk.location" "${STREAM_JSON}")
    ISO_SHA=$(jq -r ".architectures.${ARCH}.artifacts.metal.formats.iso.disk.sha256" "${STREAM_JSON}")
    info "Downloading Fedora CoreOS live ISO for SNO..."
    curl -fSL "${ISO_URL}" -o "${WORK_DIR}/downloads/fcos-live.iso"
    echo "${ISO_SHA}  ${WORK_DIR}/downloads/fcos-live.iso" | sha256sum -c -
    sudo mkdir -p "$(dirname "${LIVE_ISO}")"
    sudo cp "${WORK_DIR}/downloads/fcos-live.iso" "${LIVE_ISO}"
    sudo chmod 0644 "${LIVE_ISO}"
    ok "FCOS live ISO ready at ${LIVE_ISO}"
  fi
fi
