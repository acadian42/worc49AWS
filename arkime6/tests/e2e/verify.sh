#!/usr/bin/env bash
# E2E post-deployment verification (Phase 7). Programmatic checks over SSH + HTTP.
# Reads lab creds/IPs from .e2e-state (gitignored). Prints PASS/FAIL per check and
# a summary; writes artifacts/e2e/verify-results.txt. Never prints secret values.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/.e2e-state/secrets.env"
. "$ROOT/.e2e-state/vm_ips.env"
KEY="$ROOT/.e2e-state/e2e_ssh_key"
ART="$ROOT/artifacts/e2e"; mkdir -p "$ART"
OUT="$ART/verify-results.txt"; : > "$OUT"
SSHOPT="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
es(){ ssh $SSHOPT vagrant@"$ES_IP" "$@"; }
rec(){ ssh $SSHOPT vagrant@"$REC_IP" "$@"; }
PASS=0; FAIL=0
ck(){ # desc ; expr already evaluated -> $? ; usage: ck "desc" actual expected
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then echo "PASS | $desc (=$actual)" | tee -a "$OUT"; PASS=$((PASS+1));
  else echo "FAIL | $desc (got '$actual' want '$expected')" | tee -a "$OUT"; FAIL=$((FAIL+1)); fi
}
ckge(){ local desc="$1" actual="$2" min="$3"; if [ "${actual:-0}" -ge "$min" ] 2>/dev/null; then echo "PASS | $desc (=$actual>=$min)" | tee -a "$OUT"; PASS=$((PASS+1)); else echo "FAIL | $desc (got '$actual' want >=$min)" | tee -a "$OUT"; FAIL=$((FAIL+1)); fi; }

echo "=== Elasticsearch ===" | tee -a "$OUT"
ck "ES: exactly 3 node containers" "$(es 'sudo docker ps --format "{{.Names}}" | grep -c "^fpc-e2e-es-01-node-"' 2>/dev/null | tr -d '\r')" "3"
HEALTH=$(es "curl -s -u elastic:$VAULT_ES_BOOTSTRAP http://localhost:9200/_cluster/health" 2>/dev/null | tr -d '\r')
ck "ES: cluster status green" "$(echo "$HEALTH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status"))' 2>/dev/null)" "green"
ck "ES: number_of_nodes == 3" "$(echo "$HEALTH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("number_of_nodes"))' 2>/dev/null)" "3"
ck "ES: anonymous API access denied (401)" "$(es 'curl -s -o /dev/null -w "%{http_code}" http://localhost:9200/_cluster/health' 2>/dev/null | tr -d '\r')" "401"
ck "ES: arkime_writer can authenticate" "$(es "curl -s -o /dev/null -w '%{http_code}' -u arkime_writer:$VAULT_ES_ARKIME_WRITER http://localhost:9200/" 2>/dev/null | tr -d '\r')" "200"
ck "ES: bootstrap marker present" "$(es 'test -f /fpc/es8/.bootstrapped && echo yes || echo no' 2>/dev/null | tr -d '\r')" "yes"
ck "ES: no initial_master_nodes after bootstrap" "$(es 'grep -l cluster.initial_master_nodes /fpc/es8/config/*/elasticsearch.yml 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')" "0"
ck "ES: Xms==Xmx in every heap.options" "$(es 'for f in /fpc/es8/config/*/heap.options; do xms=$(grep -oP "(?<=-Xms)[0-9]+[gm]" $f); xmx=$(grep -oP "(?<=-Xmx)[0-9]+[gm]" $f); [ "$xms" = "$xmx" ] || echo BAD; done | grep -c BAD' 2>/dev/null | tr -d '\r')" "0"

echo "=== Arkime ===" | tee -a "$OUT"
ck "Arkime: capture container running" "$(rec 'sudo docker ps --format "{{.Names}}" | grep -c "^arkime-capture$"' 2>/dev/null | tr -d '\r')" "1"
ck "Arkime: viewer container running" "$(rec 'sudo docker ps --format "{{.Names}}" | grep -c "^arkime-viewer$"' 2>/dev/null | tr -d '\r')" "1"
ck "Arkime: capture has NET_RAW (not fully privileged)" "$(rec 'sudo docker inspect arkime-capture --format "{{.HostConfig.Privileged}}"' 2>/dev/null | tr -d '\r')" "false"
ckge "Arkime: arkime_* indices exist in ES" "$(es "curl -s -u elastic:$VAULT_ES_BOOTSTRAP http://localhost:9200/_cat/indices/arkime_*?h=index | grep -c arkime_" 2>/dev/null | tr -d '\r')" 1
ck "Arkime: viewer answers on loopback 8005" "$(rec 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8005/' 2>/dev/null | tr -d '\r')" "401"

echo "=== Nginx / security (from host over vmnet8) ===" | tee -a "$OUT"
denied(){ case "$1" in 302|401|403) echo denied;; *) echo "through:$1";; esac; }
NOAUTH=$(curl -s -k -o /dev/null -w '%{http_code}' "https://$REC_IP/" 2>/dev/null)
ck "Nginx: unauthenticated request denied (302/401/403)" "$(denied "$NOAUTH")" "denied"
ck "Nginx: HTTP redirects to HTTPS (301)" "$(curl -s -o /dev/null -w '%{http_code}' "http://$REC_IP/" 2>/dev/null)" "301"
SPOOF=$(curl -s -k -o /dev/null -w '%{http_code}' -H 'remote-user: attacker' -H 'remote-groups: arkime-admins' "https://$REC_IP/" 2>/dev/null)
ck "Security: spoofed remote-user header is rejected" "$(denied "$SPOOF")" "denied"
BYPASS=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$REC_IP:8005/" 2>/dev/null)
ck "Security: direct Viewer bypass blocked (viewer bound to loopback)" "$([ "$BYPASS" = "000" ] && echo blocked || echo "reachable:$BYPASS")" "blocked"

echo "" | tee -a "$OUT"
echo "SUMMARY: PASS=$PASS FAIL=$FAIL" | tee -a "$OUT"
[ "$FAIL" -eq 0 ]
