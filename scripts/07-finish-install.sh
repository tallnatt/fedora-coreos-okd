#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_topology

OKD_DIR="${WORK_DIR}/okd"
export KUBECONFIG="${OKD_DIR}/auth/kubeconfig"

CSR_PID=""
cleanup_csr_loop() {
  if [[ -n "${CSR_PID}" ]] && kill -0 "${CSR_PID}" >/dev/null 2>&1; then
    kill "${CSR_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_csr_loop EXIT

if [[ "${TOPOLOGY}" != "sno" ]]; then
  info "Waiting for OKD bootstrap to complete (this may take 15-30 minutes)..."
  openshift-install wait-for bootstrap-complete --dir="${OKD_DIR}" --log-level=info
  ok "Bootstrap complete!"

  BOOTSTRAP_VM="$(vm_name "bootstrap")"
  if virsh --connect "${LIBVIRT_URI}" dominfo "${BOOTSTRAP_VM}" >/dev/null 2>&1; then
    info "Removing temporary bootstrap VM '${BOOTSTRAP_VM}'..."
    virsh --connect "${LIBVIRT_URI}" destroy "${BOOTSTRAP_VM}" >/dev/null 2>&1 || true
    virsh --connect "${LIBVIRT_URI}" undefine "${BOOTSTRAP_VM}" >/dev/null 2>&1 || true
    sudo rm -f "${LIBVIRT_POOL_DIR}/${CLUSTER_NAME}-bootstrap.qcow2"
    ok "Bootstrap VM and overlay removed."
  fi

  if [[ -f /etc/haproxy/haproxy.cfg ]]; then
    info "Removing bootstrap from HAProxy backends..."
    sudo sed -i '/server bootstrap /d' /etc/haproxy/haproxy.cfg
    sudo systemctl reload haproxy || sudo systemctl restart haproxy
  fi

  info "Starting background CSR approval loop for joining nodes..."
  (
    while true; do
      oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
        | xargs -r oc adm certificate approve >/dev/null 2>&1 || true
      sleep 15
    done
  ) &
  CSR_PID=$!
fi

info "Waiting for OKD installation to complete..."
openshift-install wait-for install-complete --dir="${OKD_DIR}" --log-level=info

cleanup_csr_loop

echo ""
echo "============================================================"
echo " OKD Cluster Installation Complete!"
echo "============================================================"
echo "  Topology    : ${TOPOLOGY}"
echo "  KUBECONFIG  : ${KUBECONFIG}"
if [[ -f "${OKD_DIR}/auth/kubeadmin-password" ]]; then
  echo "  Username    : kubeadmin"
  echo "  Password    : $(<"${OKD_DIR}/auth/kubeadmin-password")"
fi
echo "  Console URL : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "============================================================"
