#!/usr/bin/env bash
# =============================================================================
# validate-awx.sh — verify AWX is reachable + admin login works, from the host.
#
#   * discovers the ACTUAL forwarded host port (never assumes 30080)
#   * GET /api/v2/ping/                      -> expect HTTP 200
#   * GET /api/v2/me/ (basic auth)           -> expect HTTP 200, username==admin
#
# The admin password is read from .state and passed via a 0600 netrc temp file,
# so it never appears in argv, logs, or `ps` output.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
setup_err_trap
load_versions

PING_RETRIES="${AWX_PING_RETRIES:-30}"
PING_DELAY="${AWX_PING_DELAY:-10}"

log_step "Validating AWX from the host"

port="$(discover_host_port "${VER_NODEPORT}")"
[[ -n "$port" ]] || die "could not discover forwarded host port for guest ${VER_NODEPORT} (run: vagrant port)"
URL="http://127.0.0.1:${port}"
log_info "AWX URL: ${URL}/   (guest NodePort ${VER_NODEPORT} -> host 127.0.0.1:${port})"

# ---- /api/v2/ping/ ---------------------------------------------------------
ping_ok=0
for ((i=1; i<=PING_RETRIES; i++)); do
  code="$(curl -fsS -m 10 -o "${CACHE_DIR}/awx_ping.json" -w '%{http_code}' "${URL}/api/v2/ping/" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then ping_ok=1; break; fi
  log_info "waiting for AWX API ${URL}/api/v2/ping/ (attempt ${i}/${PING_RETRIES}, last code=${code:-none})"
  sleep "$PING_DELAY"
done
(( ping_ok == 1 )) || die "AWX /api/v2/ping/ did not return 200 after $((PING_RETRIES*PING_DELAY))s"
awx_ver="$(jq -r '.version // "unknown"' "${CACHE_DIR}/awx_ping.json" 2>/dev/null || echo unknown)"
log_ok "/api/v2/ping/ -> 200 (AWX version: ${awx_ver})"

# ---- authenticated /api/v2/me/ --------------------------------------------
pwfile="${STATE_DIR}/awx_admin_password"
[[ -s "$pwfile" ]] || die "admin password file missing: ${pwfile}"
user="${VER_ADMIN_USER}"

netrc="$(mktemp)"; chmod 600 "$netrc"
trap 'rm -f "$netrc"' EXIT
# password read straight into the netrc file; never echoed
printf 'machine 127.0.0.1 login %s password %s\n' "$user" "$(cat "$pwfile")" > "$netrc"

code="$(curl -fsS -m 15 --netrc-file "$netrc" -o "${CACHE_DIR}/awx_me.json" \
        -w '%{http_code}' "${URL}/api/v2/me/" 2>/dev/null || true)"
rm -f "$netrc"; trap - EXIT

[[ "$code" == "200" ]] || die "authenticated /api/v2/me/ returned HTTP ${code:-none} (admin login failed)"
who="$(jq -r '.results[0].username // .username // empty' "${CACHE_DIR}/awx_me.json" 2>/dev/null || true)"
[[ "$who" == "$user" ]] || die "authenticated request did not return expected user (got '${who:-?}')"
log_ok "Authenticated as '${user}' via /api/v2/me/ -> 200"

# Persist the discovered URL for status.sh / final report (no secrets).
echo "$URL" > "${CACHE_DIR}/awx_url.txt"
log_ok "AWX validation passed."
