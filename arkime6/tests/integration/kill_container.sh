#!/usr/bin/env bash
# ============================================================================
# kill_container.sh — single ES container failure drill (replica reassignment).
#
# Stops ONE Elasticsearch container on one lab host, then polls cluster health
# until it returns to green. This exercises in-cluster recovery: the cluster
# detects the lost node, PROMOTES the surviving replica of each affected shard
# to primary, and (once disk/awareness rules allow) REASSIGNS a new replica
# onto another node.
#
# EXPECTED OUTCOME
#   * Cluster goes yellow briefly (a replica is missing / being rebuilt).
#   * No data loss: every primary still has a copy because replicas live on a
#     different physical host (allocation awareness).
#   * After the container is restarted (or a new replica is built), health
#     returns to GREEN with 0 unassigned shards.
#   * With es_index_replicas=1 the cluster tolerates exactly one node loss per
#     shard copy-set; a second simultaneous loss in the same set risks yellow
#     until recovery completes.
#
# Usage:
#   tests/integration/kill_container.sh [HOST] [NODE_NAME]
#     HOST       inventory hostname of an ES physical host (default: es-phys-01)
#     NODE_NAME  container/node to stop      (default: <HOST>-node-01)
#
# Requires: ssh access to the lab VM (vagrant ssh-config style) and the ES
# bootstrap password in $ES_BOOTSTRAP_PASSWORD for the health probe.
# ============================================================================
set -euo pipefail

HOST="${1:-es-phys-01}"
NODE_NAME="${2:-${HOST}-node-01}"
ES_HTTP_PORT="${ES_HTTP_PORT:-9200}"
ES_USER="${ES_USER:-elastic}"
ES_BOOTSTRAP_PASSWORD="${ES_BOOTSTRAP_PASSWORD:?set ES_BOOTSTRAP_PASSWORD for the health probe}"
SSH="${SSH:-ssh}"
POLL_RETRIES="${POLL_RETRIES:-60}"
POLL_DELAY="${POLL_DELAY:-10}"

echo "==> Drill: stop ES container '${NODE_NAME}' on host '${HOST}'"

# Stop the single container. docker_compose_v2 names containers <project>-<svc>;
# the service name equals the node name in the rendered compose project.
${SSH} "${HOST}" "docker stop ${NODE_NAME}"

health_status() {
  # Print just the cluster status word (green|yellow|red) from any surviving node.
  ${SSH} "${HOST}" \
    "curl -s -k -u '${ES_USER}:${ES_BOOTSTRAP_PASSWORD}' \
       'https://127.0.0.1:${ES_HTTP_PORT}/_cluster/health'" \
    | grep -oE '\"status\":\"[a-z]+\"' | cut -d'\"' -f4
}

echo "==> Confirm the cluster survives the loss (expect yellow, then recovery)"
saw_degraded=0
for _ in $(seq 1 5); do
  s="$(health_status || true)"
  echo "    status=${s:-unknown}"
  [ "${s}" = "yellow" ] && saw_degraded=1
  [ "${s}" = "red" ] && { echo "FAIL: cluster went RED — data availability lost." >&2; exit 1; }
  sleep "${POLL_DELAY}"
done
[ "${saw_degraded}" -eq 1 ] && echo "    observed expected transient yellow state."

echo "==> Restart the container and wait for full recovery to green"
${SSH} "${HOST}" "docker start ${NODE_NAME}"

for i in $(seq 1 "${POLL_RETRIES}"); do
  s="$(health_status || true)"
  echo "    [${i}/${POLL_RETRIES}] status=${s:-unknown}"
  if [ "${s}" = "green" ]; then
    echo "PASS: cluster recovered to GREEN after container loss + restart."
    exit 0
  fi
  sleep "${POLL_DELAY}"
done

echo "FAIL: cluster did not return to green within the poll window." >&2
exit 1
