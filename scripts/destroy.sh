#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve cached base FCOS images and downloaded CLI tools by default for faster re-runs;
# pass CLEAN_BASE=1 CLEAN_BIN=1 or run 'make rollback' for a full host restore.
export CLEAN_BASE="${CLEAN_BASE:-0}"
export CLEAN_BIN="${CLEAN_BIN:-0}"

exec "${SCRIPTS_DIR}/rollback.sh"
