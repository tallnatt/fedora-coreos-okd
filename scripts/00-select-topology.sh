#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "${WORK_DIR}"

if [[ -n "${TOPOLOGY:-}" ]]; then
  case "${TOPOLOGY}" in
    standard)
      info "Using pre-selected topology: standard (1 bootstrap + ${MASTER_COUNT} control-plane + ${WORKER_COUNT} workers)"
      ;;
    compact)
      WORKER_COUNT=0
      info "Using pre-selected topology: compact (1 bootstrap + ${MASTER_COUNT} control-plane, schedulable)"
      ;;
    sno)
      MASTER_COUNT=1
      WORKER_COUNT=0
      info "Using pre-selected topology: sno (Single-Node OKD, no bootstrap VM)"
      ;;
    *)
      die "Invalid TOPOLOGY='${TOPOLOGY}'. Must be one of: standard, compact, sno."
      ;;
  esac
else
  echo ""
  echo "============================================================"
  echo " Select OKD Cluster Topology"
  echo "============================================================"
  echo "  1) Standard HA    - 1 bootstrap (temp) + 3 control-plane + 2+ workers"
  echo "                    (~20+ vCPU, ~80+ GB RAM peak)"
  echo "  2) Compact 3-node - 1 bootstrap (temp) + 3 control-plane (schedulable)"
  echo "                    (~16 vCPU, ~64 GB RAM peak)"
  echo "  3) Single-Node    - 1 node total (bootstrap-in-place, no HA)"
  echo "                    (~8 vCPU, ~24 GB RAM)"
  echo ""

  while true; do
    read -rp "Enter choice [1-3] (default: 2): " choice
    choice="${choice:-2}"
    case "${choice}" in
      1)
        TOPOLOGY="standard"
        read -rp "Number of worker nodes (minimum 2, default ${WORKER_COUNT}): " w_in
        WORKER_COUNT="${w_in:-${WORKER_COUNT}}"
        if ! [[ "${WORKER_COUNT}" =~ ^[0-9]+$ ]] || (( WORKER_COUNT < 2 )); then
          warn "Standard HA requires at least 2 workers; setting WORKER_COUNT=2."
          WORKER_COUNT=2
        fi
        break
        ;;
      2)
        TOPOLOGY="compact"
        WORKER_COUNT=0
        break
        ;;
      3)
        TOPOLOGY="sno"
        MASTER_COUNT=1
        WORKER_COUNT=0
        break
        ;;
      *)
        echo "Please enter 1, 2, or 3."
        ;;
    esac
  done
fi

cat > "${WORK_DIR}/.topology.env" <<EOF
TOPOLOGY="${TOPOLOGY}"
MASTER_COUNT="${MASTER_COUNT}"
WORKER_COUNT="${WORKER_COUNT}"
EOF

ok "Topology saved to ${WORK_DIR}/.topology.env: TOPOLOGY=${TOPOLOGY} (masters=${MASTER_COUNT}, workers=${WORKER_COUNT})"
