#!/usr/bin/env bash
# =============================================================================
# destroy.sh — destroy ONLY this project's Vagrant VM. Requires --yes or an
# interactive confirmation. Never touches any other VMware VM.
# =============================================================================
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"
setup_err_trap

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

st="$(vm_state || echo absent)"
log_info "Project VM state: ${st}"
if [[ "$st" == "absent" || "$st" == "not_created" ]]; then
  log_ok "No project VM to destroy."
  exit 0
fi

if (( ASSUME_YES == 0 )); then
  log_warn "This will destroy ONLY this project's VM (defined by ./Vagrantfile)."
  confirm "Destroy the project VM now?" || { log_info "Aborted."; exit 0; }
fi

log_step "Destroying project VM (vagrant destroy -f)"
( cd "$PROJECT_DIR" && vagrant destroy -f )
log_ok "Project VM destroyed."
log_info "Secrets in .state/ are preserved so a later ./install.sh reuses the same credentials."
log_info "To wipe everything: rm -rf .state .cache .artifacts inventory/generated/hosts.ini"
