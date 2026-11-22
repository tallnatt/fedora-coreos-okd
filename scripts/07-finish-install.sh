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

  BOOTSTRAP_VM="$(get_nodes | awk '$1 == "bootstrap" {print $5}')"
  BOOTSTRAP_OVERLAY="$(get_nodes | awk '$1 == "bootstrap" {print $6}')"
  BOOTSTRAP_VM="${BOOTSTRAP_VM:-$(vm_name "bootstrap")}"
  BOOTSTRAP_OVERLAY="${BOOTSTRAP_OVERLAY:-${LIBVIRT_POOL_DIR}/${CLUSTER_NAME}-bootstrap.qcow2}"
  if virsh --connect "${LIBVIRT_URI}" dominfo "${BOOTSTRAP_VM}" >/dev/null 2>&1; then
    info "Removing temporary bootstrap VM '${BOOTSTRAP_VM}'..."
    virsh --connect "${LIBVIRT_URI}" destroy "${BOOTSTRAP_VM}" >/dev/null 2>&1 || true
    virsh --connect "${LIBVIRT_URI}" undefine "${BOOTSTRAP_VM}" >/dev/null 2>&1 || true
    sudo rm -f "${BOOTSTRAP_OVERLAY}"
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

if [[ -n "${KUBEADMIN_PASSWORD:-}" ]]; then
  info "Applying custom kubeadmin password..."
  KUBEADMIN_HASH=""
  if command -v htpasswd >/dev/null 2>&1; then
    KUBEADMIN_HASH=$(htpasswd -bnBC 10 "" "${KUBEADMIN_PASSWORD}" | tr -d ':\n')
  elif command -v python3 >/dev/null 2>&1; then
    KUBEADMIN_HASH=$(python3 -c 'import sys, bcrypt; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=10, prefix=b"2y")).decode())' "${KUBEADMIN_PASSWORD}" 2>/dev/null || true)
  fi

  if [[ -n "${KUBEADMIN_HASH}" ]]; then
    if oc create secret generic kubeadmin -n kube-system \
      --from-literal=kubeadmin="${KUBEADMIN_HASH}" \
      --dry-run=client -o yaml | oc replace -f - >/dev/null; then
      printf '%s' "${KUBEADMIN_PASSWORD}" > "${OKD_DIR}/auth/kubeadmin-password"
      chmod 0600 "${OKD_DIR}/auth/kubeadmin-password"
      ok "Updated kubeadmin password in cluster and ${OKD_DIR}/auth/kubeadmin-password."
    else
      warn "Failed to update kubeadmin secret; keeping auto-generated password."
    fi
  else
    warn "Neither 'htpasswd' nor Python 'bcrypt' is available to hash kubeadmin password; keeping auto-generated password."
  fi
fi

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
