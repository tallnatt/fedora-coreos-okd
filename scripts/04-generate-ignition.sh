#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_topology

OKD_DIR="${WORK_DIR}/okd"
BUTANE_DIR="${WORK_DIR}/butane"
IGN_DIR="${WORK_DIR}/ignition"
POOL_IGN_DIR="${LIBVIRT_POOL_DIR}/ignition"

rm -rf "${OKD_DIR}" "${BUTANE_DIR}" "${IGN_DIR}"
mkdir -p "${OKD_DIR}" "${BUTANE_DIR}" "${IGN_DIR}"
sudo mkdir -p "${POOL_IGN_DIR}"

SSH_PUB_KEY="$(<"${SSH_PUB_KEY_PATH}")"
if [[ -n "${PULL_SECRET_PATH}" && -f "${PULL_SECRET_PATH}" ]]; then
  PULL_SECRET="$(tr -d '\n' < "${PULL_SECRET_PATH}")"
else
  # OKD community images do not require a Red Hat pull secret
  PULL_SECRET='{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'
fi

# Determine compute/controlPlane replicas for install-config.yaml
case "${TOPOLOGY}" in
  standard)
    CP_REPLICAS="${MASTER_COUNT}"
    COMPUTE_REPLICAS="${WORKER_COUNT}"
    ;;
  compact)
    CP_REPLICAS="${MASTER_COUNT}"
    COMPUTE_REPLICAS="0"
    ;;
  sno)
    CP_REPLICAS="1"
    COMPUTE_REPLICAS="0"
    ;;
esac

info "Generating install-config.yaml for topology '${TOPOLOGY}' (controlPlane=${CP_REPLICAS}, compute=${COMPUTE_REPLICAS})..."

cat > "${OKD_DIR}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- name: worker
  replicas: ${COMPUTE_REPLICAS}
  architecture: amd64
controlPlane:
  name: master
  replicas: ${CP_REPLICAS}
  architecture: amd64
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUB_KEY}'
EOF

if [[ "${TOPOLOGY}" == "sno" ]]; then
  cat >> "${OKD_DIR}/install-config.yaml" <<EOF
bootstrapInPlace:
  installationDisk: /dev/vda
EOF
fi

cp "${OKD_DIR}/install-config.yaml" "${WORK_DIR}/install-config.yaml.bak"

info "Running openshift-install to generate base OKD Ignition configs..."
if [[ "${TOPOLOGY}" == "sno" ]]; then
  openshift-install create single-node-ignition-config --dir="${OKD_DIR}"
else
  openshift-install create ignition-configs --dir="${OKD_DIR}"
fi

info "Generating per-node Butane configs and compiling Ignition files..."
while read -r name role ip mac vcpu ram_mb disk_gb; do
  case "${role}" in
    bootstrap) base_ign="bootstrap.ign" ;;
    master)    base_ign="master.ign" ;;
    worker)    base_ign="worker.ign" ;;
    sno)       base_ign="bootstrap-in-place-for-live-iso.ign" ;;
    *)         die "Unknown node role: ${role}" ;;
  esac

  bu_file="${BUTANE_DIR}/${name}.bu"
  ign_file="${IGN_DIR}/${name}.ign"

  cat > "${bu_file}" <<EOF
variant: fcos
version: 1.5.0
ignition:
  config:
    merge:
      - local: ${base_ign}
storage:
  files:
    - path: /etc/hostname
      mode: 0644
      overwrite: true
      contents:
        inline: |
          ${name}.${CLUSTER_NAME}.${BASE_DOMAIN}
EOF

  butane --strict --files-dir "${OKD_DIR}" "${bu_file}" -o "${ign_file}"
  sudo cp "${ign_file}" "${POOL_IGN_DIR}/${name}.ign"
  sudo chmod 0644 "${POOL_IGN_DIR}/${name}.ign"
  ok "Generated Ignition for ${name} -> ${POOL_IGN_DIR}/${name}.ign"
done < <(get_nodes)

# For SNO, embed the Butane-compiled Ignition config into a live ISO
if [[ "${TOPOLOGY}" == "sno" ]]; then
  SNO_ISO="${LIBVIRT_POOL_DIR}/fcos-sno.iso"
  info "Embedding Ignition config into SNO live ISO (${SNO_ISO})..."
  sudo cp "${LIBVIRT_POOL_DIR}/fcos-live.iso" "${SNO_ISO}"
  if command -v coreos-installer >/dev/null 2>&1; then
    sudo coreos-installer iso ignition embed -f -i "${POOL_IGN_DIR}/sno-0.ign" "${SNO_ISO}"
  elif command -v podman >/dev/null 2>&1; then
    sudo podman run --privileged --rm -v "${LIBVIRT_POOL_DIR}:/data" -w /data \
      quay.io/coreos/coreos-installer:release iso ignition embed -f -i /data/ignition/sno-0.ign /data/fcos-sno.iso
  else
    die "Neither coreos-installer nor podman is available to embed Ignition into the SNO live ISO."
  fi
  sudo chmod 0644 "${SNO_ISO}"
  ok "SNO live ISO ready at ${SNO_ISO}"
fi

if command -v restorecon >/dev/null 2>&1; then
  sudo restorecon -Rv "${LIBVIRT_POOL_DIR}" >/dev/null 2>&1 || true
fi
