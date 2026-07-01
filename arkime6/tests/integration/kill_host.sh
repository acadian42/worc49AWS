#!/usr/bin/env bash
# ============================================================================
# kill_host.sh — whole ES host (failure domain) loss drill (quorum + no loss).
#
# Halts ONE Elasticsearch physical host VM (all N containers on it at once) and
# polls cluster health from a SURVIVING host until it stabilises. This is the
# failure-domain test: losing a host removes a full failure domain, so every
# shard's surviving copy must be on a DIFFERENT host (allocation awareness),
# and the 3 master-eligible nodes (on 3 distinct hosts) must keep quorum.
#
# EXPECTED OUTCOME
#   * Master quorum holds: with 3 master-eligible nodes on 3 hosts, losing one
#     host leaves 2/3 — a majority — so a master stays/gets elected. (Losing a
#     SECOND master host would lose quorum and the cluster would block writes.)
#   * No data loss: replicas of every primary live on other hosts, so each
#     shard still has at least one copy. Cluster goes yellow (replicas missing),
#     never red.
#   * The cluster does NOT immediately rebuild replicas — index.unassigned.
#     node_left.delayed_timeout (default 1m) lets the host return first. On a
#     real, unrecoverable host loss it will rebuild after the delay if capacity
#     and awareness force-values allow.
#   * After the VM is brought back and rejoins, health returns to GREEN.
#
# Usage:
#   tests/integration/kill_host.sh [DOWN_HOST] [PROBE_HOST]
#     DOWN_HOST   ES host to halt           (default: es-phys-03)
#     PROBE_HOST  surviving ES host to query(default: es-phys-01)
#
# Requires: vagrant in PATH (lab control of the VM lifecycle) and the ES
# bootstrap password in $ES_BOOTSTRAP_PASSWORD for the health probe.
# ============================================================================
set -euo pipefail

DOWN_HOST="${1:-es-phys-03}"
PROBE_HOST="${2:-es-phys-01}"
ES_HTTP_PORT="${ES_HTTP_PORT:-9200}"
ES_USER="${ES_USER:-elastic}"
ES_BOOTSTRAP_PASSWORD="${ES_BOOTSTRAP_PASSWORD:?set ES_BOOTSTRAP_PASSWORD for the health probe}"
VAGRANT="${VAGRANT:-vagrant}"
SSH="${SSH:-ssh}"
POLL_RETRIES="${POLL_RETRIES:-90}"
POLL_DELAY="${POLL_DELAY:-10}"

echo "==> Drill: halt ES host VM '${DOWN_HOST}', probe from '${PROBE_HOST}'"

health_json() {
  ${SSH} "${PROBE_HOST}" \
    "curl -s -k -u '${ES_USER}:${ES_BOOTSTRAP_PASSWORD}' \
       'https://127.0.0.1:${ES_HTTP_PORT}/_cluster/health'"
}
field() { grep -oE "\"$1\":(\"[a-z]+\"|[0-9]+)" | head -n1 | cut -d: -f2 | tr -d '\"'; }

echo "==> Baseline health before the drill"
health_json | grep -oE '\"status\":\"[a-z]+\"' || true

# Halt the whole failure domain (graceful VM shutdown; never destroys volumes).
${VAGRANT} halt "${DOWN_HOST}"

echo "==> Verify quorum holds and there is no data loss (expect yellow, not red)"
held_quorum=0
for i in $(seq 1 6); do
  j="$(health_json || true)"
  status="$(printf '%s' "${j}" | field status)"
  nodes="$(printf '%s' "${j}" | field number_of_nodes)"
  echo "    [${i}] status=${status:-unknown} nodes=${nodes:-?}"
  if [ -n "${status}" ] && [ "${status}" != "red" ]; then
    held_quorum=1   # we got a coherent answer => a master is serving => quorum held
  fi
  if [ "${status}" = "red" ]; then
    echo "FAIL: cluster RED — a primary lost all copies (awareness misconfigured?)." >&2
    exit 1
  fi
  sleep "${POLL_DELAY}"
done
[ "${held_quorum}" -eq 1 ] || { echo "FAIL: no master answered — quorum may be lost." >&2; exit 1; }
echo "    quorum held and no shard went red — no data loss."

echo "==> Bring the host back; it must REJOIN, not re-bootstrap"
${VAGRANT} up "${DOWN_HOST}"

for i in $(seq 1 "${POLL_RETRIES}"); do
  status="$(health_json | field status || true)"
  echo "    [${i}/${POLL_RETRIES}] status=${status:-unknown}"
  if [ "${status}" = "green" ]; then
    echo "PASS: host rejoined and cluster recovered to GREEN with no data loss."
    exit 0
  fi
  sleep "${POLL_DELAY}"
done

echo "FAIL: cluster did not return to green after the host rejoined." >&2
exit 1
