#!/usr/bin/env bash
# =============================================================================
# tests/integration.sh — 15 live acceptance checks against the running system.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=../scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"
load_versions
NS="${VER_NAMESPACE}"
VENV="${VENV_DIR}/bin"

declare -i N=0 PASS=0 FAIL=0
pass() { N+=1; PASS+=1; log_ok   "#${N} $1"; }
fail() { N+=1; FAIL+=1; log_error "#${N} $1"; }
gssh() { ( cd "$PROJECT_DIR" && vagrant ssh -c "$1" ) 2>/dev/null; }

log_step "Live integration tests"

# Ensure inventory is fresh for the ansible ping test.
"${PROJECT_DIR}/scripts/generate-inventory.sh" >/dev/null 2>&1 || true

# 1. provider
if ls -d "${PROJECT_DIR}"/.vagrant/machines/*/vmware_desktop >/dev/null 2>&1; then
  pass "Vagrant provider is vmware_desktop"; else fail "Vagrant provider is not vmware_desktop"; fi

# 2. guest OS
osid="$(gssh 'grep -m1 VERSION_ID /etc/os-release || true')"
[[ "$osid" == *24.04* ]] && pass "guest reports Ubuntu 24.04" || fail "guest is not Ubuntu 24.04 (${osid:-?})"

# 3. ansible ping
if [[ -x "${VENV}/ansible" ]] && ( cd "$PROJECT_DIR" && "${VENV}/ansible" awx_vm -m ping -o >/dev/null 2>&1 ); then
  pass "Ansible ping succeeds"; else fail "Ansible ping failed"; fi

# 4. k3s active
[[ "$(gssh 'systemctl is-active k3s')" == active ]] && pass "K3s service active" || fail "K3s service not active"

# 5. node Ready
nodes="$(gssh 'sudo k3s kubectl get nodes --no-headers')"
grep -qw Ready <<<"$nodes" && pass "Kubernetes node Ready" || fail "Kubernetes node not Ready"

# 6. local-path storageclass functional (ephemeral PVC+pod bind smoke test)
storage_smoke() {
  local nm="lpsmoke"
  gssh "sudo k3s kubectl delete pod ${nm} pvc ${nm} -n default --ignore-not-found >/dev/null 2>&1; \
        printf '%s' 'apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${nm}
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${nm}
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: busybox:1.36
    command: [sh, -c, \"echo ok > /data/ok; sleep 3\"]
    volumeMounts:
    - { name: v, mountPath: /data }
  volumes:
  - name: v
    persistentVolumeClaim:
      claimName: ${nm}' | sudo k3s kubectl apply -f - >/dev/null 2>&1"
  local ph=""
  for _ in $(seq 1 24); do
    ph="$(gssh "sudo k3s kubectl -n default get pvc ${nm} -o jsonpath='{.status.phase}'" 2>/dev/null)"
    [[ "$ph" == "Bound" ]] && break
    sleep 5
  done
  gssh "sudo k3s kubectl -n default delete pod ${nm} pvc ${nm} --grace-period=0 --force >/dev/null 2>&1" || true
  [[ "$ph" == "Bound" ]]
}
if storage_smoke; then pass "local-path storage provisions a PVC"; else fail "local-path PVC did not Bind"; fi

# 7. operator Available
[[ "$(gssh "sudo k3s kubectl -n ${NS} get deploy awx-operator-controller-manager -o jsonpath='{.status.availableReplicas}'")" =~ ^[1-9] ]] \
  && pass "AWX Operator Deployment Available" || fail "AWX Operator not Available"

# 8. AWX CR reconciled (Running/True condition)
if gssh "sudo k3s kubectl -n ${NS} get awx ${VER_RESOURCE} -o json | jq -e '.status.conditions[]? | select(.type==\"Running\" and .status==\"True\")' >/dev/null 2>&1"; then
  pass "AWX CR reconciled (Running=True)"
elif gssh "sudo k3s kubectl -n ${NS} get awx ${VER_RESOURCE}" >/dev/null 2>&1 \
     && [[ "$(gssh "sudo k3s kubectl -n ${NS} get deploy ${VER_RESOURCE}-web -o jsonpath='{.status.availableReplicas}'")" =~ ^[1-9] ]]; then
  pass "AWX CR reconciled (web Available)"
else
  fail "AWX CR not reconciled"
fi

# 9. postgres PVC Bound
pvcphase="$(gssh "sudo k3s kubectl -n ${NS} get pvc -o jsonpath='{.items[*].status.phase}'")"
grep -qw Bound <<<"$pvcphase" && pass "PostgreSQL PVC Bound" || fail "no Bound PVC in ${NS}"

# 10. web + task ready
w="$(gssh "sudo k3s kubectl -n ${NS} get deploy ${VER_RESOURCE}-web  -o jsonpath='{.status.availableReplicas}'")"
t="$(gssh "sudo k3s kubectl -n ${NS} get deploy ${VER_RESOURCE}-task -o jsonpath='{.status.availableReplicas}'")"
[[ "$w" =~ ^[1-9] && "$t" =~ ^[1-9] ]] && pass "AWX web+task containers ready" || fail "AWX web/task not ready (web=${w:-0} task=${t:-0})"

# 11. NodePort 30080
svcnp="$(gssh "sudo k3s kubectl -n ${NS} get svc ${VER_RESOURCE}-service -o jsonpath='{.spec.ports[*].nodePort}'")"
grep -qw "${VER_NODEPORT}" <<<"$svcnp" && pass "NodePort service exposes ${VER_NODEPORT}" || fail "NodePort ${VER_NODEPORT} not found"

# 12. discover host port
port="$(discover_host_port "${VER_NODEPORT}" 2>/dev/null || true)"
[[ -n "$port" ]] && pass "forwarded host port discovered (${port})" || fail "could not discover forwarded host port"

# 13. host ping 200
if [[ -n "$port" ]]; then
  code="$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/api/v2/ping/" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && pass "host GET /api/v2/ping/ -> 200" || fail "host /api/v2/ping/ -> ${code}"
else
  fail "host /api/v2/ping/ skipped (no port)"
fi

# 14. authenticated /api/v2/me/ 200 (no password in logs)
if [[ -n "$port" && -s "${STATE_DIR}/awx_admin_password" ]]; then
  nrc="$(mktemp)"; chmod 600 "$nrc"
  printf 'machine 127.0.0.1 login %s password %s\n' "${VER_ADMIN_USER}" "$(cat "${STATE_DIR}/awx_admin_password")" > "$nrc"
  mcode="$(curl -fsS -m 12 --netrc-file "$nrc" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/api/v2/me/" 2>/dev/null || echo 000)"
  rm -f "$nrc"
  [[ "$mcode" == "200" ]] && pass "authenticated /api/v2/me/ -> 200" || fail "authenticated /api/v2/me/ -> ${mcode}"
else
  fail "authenticated check skipped (no port or password)"
fi

# 15. status.sh healthy
if "${PROJECT_DIR}/status.sh" >/dev/null 2>&1; then pass "status.sh reports healthy"; else fail "status.sh reports unhealthy"; fi

# Informational: migration job Completed (treated as success, not failure)
mig="$(gssh "sudo k3s kubectl -n ${NS} get jobs -o jsonpath='{range .items[*]}{.metadata.name}={.status.succeeded}{\" \"}{end}'" 2>/dev/null || true)"
log_info "migration jobs (name=succeeded): ${mig:-none}"

log_step "Integration summary: ${PASS}/${N} passed, ${FAIL} failed"
(( FAIL == 0 )) || exit 1
