#!/usr/bin/env bash
# =============================================================================
# tests/idempotence.sh — re-run install.sh and assert nothing was recreated.
#   * exits 0
#   * VM not recreated (same VMware machine id)
#   * AWX secrets not regenerated (same content hash)
#   * URL + credentials still work
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=../scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"
load_versions

declare -i FAIL=0
ok()  { log_ok "$1"; }
bad() { log_error "$1"; FAIL=$((FAIL+1)); }

machine_id() { cat "${PROJECT_DIR}"/.vagrant/machines/*/vmware_desktop/id 2>/dev/null | head -1; }
hashf() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

log_step "Idempotence: capturing pre-state"
id_before="$(machine_id || true)"
pw_before="$(hashf "${STATE_DIR}/awx_admin_password")"
sk_before="$(hashf "${STATE_DIR}/awx_secret_key")"
[[ -n "$id_before" ]] && log_info "VM id: ${id_before:0:12}…" || log_warn "no VM id found (was it installed?)"

log_step "Idempotence: re-running ./install.sh"
if ./install.sh; then ok "second ./install.sh exited 0"; else bad "second ./install.sh failed"; fi

log_step "Idempotence: comparing post-state"
id_after="$(machine_id || true)"
pw_after="$(hashf "${STATE_DIR}/awx_admin_password")"
sk_after="$(hashf "${STATE_DIR}/awx_secret_key")"
port_after="$(discover_host_port "${VER_NODEPORT}" 2>/dev/null || true)"

[[ -n "$id_before" && "$id_before" == "$id_after" ]] && ok "VM was NOT recreated" || bad "VM id changed (recreated?)"
[[ "$pw_before" == "$pw_after" ]] && ok "admin password unchanged" || bad "admin password regenerated!"
[[ "$sk_before" == "$sk_after" ]] && ok "secret key unchanged" || bad "secret key regenerated!"

if [[ -n "$port_after" ]]; then
  code="$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port_after}/api/v2/ping/" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && ok "AWX still reachable (/api/v2/ping/ 200)" || bad "AWX not reachable after rerun (${code})"
else
  bad "no forwarded port after rerun"
fi

log_step "Idempotence summary"
(( FAIL == 0 )) && { log_ok "idempotence PASSED"; exit 0; } || { log_error "idempotence FAILED (${FAIL})"; exit 1; }
