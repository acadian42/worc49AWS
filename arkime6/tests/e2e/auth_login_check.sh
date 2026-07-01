#!/usr/bin/env bash
# Authentication flow checks against the live Nginx+LDAP front door and the
# Arkime viewer. Reads creds/IPs from .e2e-state. No secrets printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/.e2e-state/secrets.env"; . "$ROOT/.e2e-state/vm_ips.env"
KEY="$ROOT/.e2e-state/e2e_ssh_key"
ART="$ROOT/artifacts/e2e"; mkdir -p "$ART"; OUT="$ART/auth-results.txt"; : > "$OUT"
SSHOPT="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
B="https://$REC_IP"
PASS=0; FAIL=0
ck(){ if [ "$2" = "$3" ]; then echo "PASS | $1 (=$2)" | tee -a "$OUT"; PASS=$((PASS+1)); else echo "FAIL | $1 (got '$2' want '$3')" | tee -a "$OUT"; FAIL=$((FAIL+1)); fi; }
rec(){ ssh $SSHOPT vagrant@"$REC_IP" "$@"; }

# --- helper: perform an LDAP form login, return final auth status of GET / ---
ldap_login(){ # user pass -> echoes the http_code of an authenticated GET /
  local u="$1" p="$2" jar; jar=$(mktemp)
  local page; page=$(curl -s -k -c "$jar" "$B/auth/login?service=$B/" 2>/dev/null)
  # extract the CSRF hidden field if present
  local csrf; csrf=$(echo "$page" | grep -oiE 'name="[^"]*csrf[^"]*"[^>]*value="[^"]*"' | grep -oE 'value="[^"]*"' | head -1 | sed 's/value="//; s/"//')
  curl -s -k -b "$jar" -c "$jar" -o /dev/null \
    --data-urlencode "username=$u" --data-urlencode "password=$p" \
    --data-urlencode "csrf_token=$csrf" --data-urlencode "service=$B/" "$B/auth/login" 2>/dev/null
  local code; code=$(curl -s -k -b "$jar" -o /dev/null -w '%{http_code}' "$B/api/user" 2>/dev/null)
  rm -f "$jar"; echo "$code"
}

echo "=== Authentication ===" | tee -a "$OUT"
VALID=$(ldap_login "analyst" "labpass-analyst-e2e")
ck "Valid LDAP login (analyst) reaches the viewer (200)" "$VALID" "200"
INVALID=$(ldap_login "analyst" "definitely-wrong-password")
case "$INVALID" in 200) ck "Invalid LDAP login is denied" "authenticated" "denied";; *) ck "Invalid LDAP login is denied" "denied" "denied";; esac

echo "=== Local emergency login (Arkime digest admin, viewer loopback) ===" | tee -a "$OUT"
EMER=$(rec "curl -s --digest -u admin:$VAULT_ARKIME_ADMIN -o /dev/null -w '%{http_code}' http://127.0.0.1:8005/api/user" 2>/dev/null | tr -d '\r')
ck "Emergency local digest admin authenticates at the viewer" "$EMER" "200"
EMERBAD=$(rec "curl -s --digest -u admin:wrong-pw -o /dev/null -w '%{http_code}' http://127.0.0.1:8005/api/user" 2>/dev/null | tr -d '\r')
ck "Wrong emergency password is rejected (401)" "$EMERBAD" "401"

echo "=== LDAP outage fails closed ===" | tee -a "$OUT"
rec 'sudo docker stop fpc-e2e-ldap >/dev/null 2>&1'
OUT_CODE=$(ldap_login "analyst" "labpass-analyst-e2e")
case "$OUT_CODE" in 200) ck "LDAP outage does NOT grant access (fail-closed)" "granted" "denied";; *) ck "LDAP outage fails closed (login denied)" "denied" "denied";; esac
rec 'sudo docker start fpc-e2e-ldap >/dev/null 2>&1'; sleep 5

echo "" | tee -a "$OUT"; echo "SUMMARY: PASS=$PASS FAIL=$FAIL" | tee -a "$OUT"
[ "$FAIL" -eq 0 ]
