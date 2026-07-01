#!/usr/bin/env bash
# =============================================================================
# diagnose.sh — collect a fresh redacted diagnostic bundle on demand.
# =============================================================================
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"
out="$("${PROJECT_DIR}/scripts/collect-diagnostics.sh" "$@" | tail -1)"
log_ok "Diagnostics ready: ${out}"
log_info "Bundle contains NO secrets (auth headers, passwords, keys, kubeconfig redacted)."
