#!/usr/bin/env bash
# Import the deterministic fixture PCAP into Arkime (offline) and verify the
# session is searchable in Elasticsearch with the expected metadata, plus a
# best-effort PCAP retrieval via the Viewer API. Reads creds/IPs from .e2e-state.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/.e2e-state/secrets.env"
. "$ROOT/.e2e-state/vm_ips.env"
KEY="$ROOT/.e2e-state/e2e_ssh_key"
ART="$ROOT/artifacts/e2e"; mkdir -p "$ART"; OUT="$ART/arkime-ingest.txt"; : > "$OUT"
SSHOPT="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
PCAP="$ROOT/tests/e2e/fixtures/fpc-e2e-fixture.pcap"
ESQ="curl -s -u elastic:$VAULT_ES_BOOTSTRAP"
PASS=0; FAIL=0
ckge(){ if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then echo "PASS | $1 (=$2>=$3)" | tee -a "$OUT"; PASS=$((PASS+1)); else echo "FAIL | $1 (got '$2' want >=$3)" | tee -a "$OUT"; FAIL=$((FAIL+1)); fi; }
rec(){ ssh $SSHOPT vagrant@"$REC_IP" "$@"; }

echo "=== Arkime ingestion (offline import of fixture PCAP) ===" | tee -a "$OUT"
scp $SSHOPT "$PCAP" vagrant@"$REC_IP":/tmp/fpc-e2e-fixture.pcap >/dev/null 2>&1
rec 'sudo docker cp /tmp/fpc-e2e-fixture.pcap arkime-capture:/tmp/fpc-e2e-fixture.pcap' >/dev/null 2>&1
rec 'sudo docker exec arkime-capture /opt/arkime/bin/capture -c /opt/arkime/etc/config.ini -r /tmp/fpc-e2e-fixture.pcap --copy >/tmp/imp.log 2>&1; tail -1 /tmp/imp.log' 2>/dev/null | tr -d '\r' | tee -a "$OUT"
sleep 6
$ESQ "http://$ES_IP:9200/arkime_sessions3*/_refresh" -o /dev/null 2>/dev/null

DST=$($ESQ "http://$ES_IP:9200/arkime_sessions3*/_search?q=10.99.0.80&size=0" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["hits"]["total"]["value"])' 2>/dev/null)
ckge "Arkime: fixture sessions searchable (dst 10.99.0.80)" "$DST" 1
SRC=$($ESQ "http://$ES_IP:9200/arkime_sessions3*/_search?size=1&q=10.99.0.80" 2>/dev/null | grep -c '10.99.0.10' || echo 0)
ckge "Arkime: session metadata has source 10.99.0.10" "$SRC" 1
DNS=$($ESQ "http://$ES_IP:9200/arkime_sessions3*/_search?q=fpc-e2e-smoke.example.test&size=0" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["hits"]["total"]["value"])' 2>/dev/null)
ckge "Arkime: DNS fixture host searchable (fpc-e2e-smoke.example.test)" "$DNS" 1

echo "=== PCAP retrieval via Viewer API (digest admin, loopback) ===" | tee -a "$OUT"
# Pull one session's node+id, then retrieve its PCAP through the viewer.
read -r NODE SID < <($ESQ "http://$ES_IP:9200/arkime_sessions3*/_search?size=1&q=10.99.0.80" 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin)["hits"]["hits"][0]
print(d["_source"].get("node",""), d["_id"])' 2>/dev/null)
echo "session node=$NODE id=$SID" | tee -a "$OUT"
PCBYTES=$(rec "curl -s --digest -u admin:$VAULT_ARKIME_ADMIN 'http://127.0.0.1:8005/api/session/$NODE/$SID/pcap' -o /tmp/out.pcap -w '%{size_download}' 2>/dev/null; stat -c%s /tmp/out.pcap 2>/dev/null" 2>/dev/null | tr -d '\r' | tail -1)
ckge "Arkime: PCAP retrieval returns bytes for a fixture session" "${PCBYTES:-0}" 1

echo "" | tee -a "$OUT"; echo "SUMMARY: PASS=$PASS FAIL=$FAIL" | tee -a "$OUT"
[ "$FAIL" -eq 0 ]
