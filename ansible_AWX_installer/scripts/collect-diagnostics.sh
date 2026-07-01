#!/usr/bin/env bash
# =============================================================================
# collect-diagnostics.sh — gather a redacted diagnostic bundle for debugging.
# Best-effort: never aborts; every capture is independent. Secrets are scrubbed.
# Usage: collect-diagnostics.sh [output_dir]
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_versions
NS="${VER_NAMESPACE:-awx}"

OUT="${1:-${ARTIFACTS_DIR}/diag-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
log_step "Collecting diagnostics -> ${OUT}"

# cap <file> <command...> : run on host, redact, save (never abort)
cap() {
  local f="$1"; shift
  { echo "### \$ $*"; "$@" 2>&1 || echo "[command failed: exit $?]"; } | redact > "${OUT}/${f}" || true
}
# capg <file> <guest-shell-command> : run inside the guest via vagrant ssh
capg() {
  local f="$1" cmd="$2"
  { echo "### (guest) \$ ${cmd}"
    ( cd "$PROJECT_DIR" && vagrant ssh -c "$cmd" ) 2>&1 || echo "[guest command failed: exit $?]"
  } | redact > "${OUT}/${f}" || true
}
kc() { printf 'sudo k3s kubectl %s' "$*"; }   # build a guest kubectl command string

# ---- Host -----------------------------------------------------------------
cap host-uname.txt        uname -a
cap host-os-release.txt   cat /etc/os-release
cap host-cpu.txt          bash -c 'lscpu | grep -Ei "model name|^cpu\(s\)|virtuali|flags" | head'
cap host-mem.txt          free -h
cap host-disk.txt         df -h
cap host-vmware.txt       bash -c 'vmware -v; echo; lsmod | grep -E "vmmon|vmnet" || echo "modules not loaded"'
cap host-vmware-net.txt   bash -c 'sudo -n vmware-networks --status 2>&1 || echo "n/a"'
cap host-vagrant.txt      bash -c 'vagrant --version; echo; vagrant plugin list; echo; vagrant-vmware-utility -v 2>&1 || true'
cap host-vagrant-status.txt bash -c "cd '$PROJECT_DIR' && vagrant status"
cap host-vagrant-port.txt   bash -c "cd '$PROJECT_DIR' && vagrant port 2>&1 || true"
# ssh-config with the IdentityFile path redacted (path, not key content)
{ echo "### \$ vagrant ssh-config"; ( cd "$PROJECT_DIR" && vagrant ssh-config 2>&1 ) \
    | sed -E 's#(IdentityFile).*#\1 [REDACTED]#I'; } > "${OUT}/host-ssh-config.txt" 2>&1 || true

# ---- Guest / Kubernetes ----------------------------------------------------
capg guest-os.txt          'cat /etc/os-release; echo; df -h; echo; free -h'
capg guest-k3s-systemd.txt 'sudo systemctl status k3s --no-pager 2>&1 | head -40'
capg guest-k3s-journal.txt 'sudo journalctl -u k3s --no-pager -n 200 2>&1 | tail -200'
capg guest-kubever.txt     "$(kc version) 2>&1; $(kc get nodes -o wide)"
capg guest-nodes.txt       "$(kc get nodes -o wide)"
capg guest-sc.txt          "$(kc get storageclass)"
capg guest-awx-all.txt     "$(kc get all,pvc,pv -n "$NS" -o wide)"
# secrets: NAMES + types only, never -o yaml (no data leak); still redacted
capg guest-awx-secrets.txt "$(kc get secrets -n "$NS")"
capg guest-events.txt      "$(kc get events -A --sort-by=.lastTimestamp) 2>&1 | tail -120"
capg guest-pods-wide.txt   "$(kc get pods -n "$NS" -o wide)"

# describe + logs for anything not Running/Completed/Ready
capg guest-describe-bad.txt '
  for p in $(sudo k3s kubectl get pods -n '"$NS"' --no-headers 2>/dev/null \
       | awk "\$3!=\"Running\" && \$3!=\"Completed\"{print \$1}"); do
    echo "===== describe pod $p ====="; sudo k3s kubectl describe pod -n '"$NS"' "$p" 2>&1 | tail -60; echo;
  done; echo "(if empty, all pods are Running/Completed)"'
capg guest-operator-logs.txt \
  'sudo k3s kubectl logs -n '"$NS"' deploy/awx-operator-controller-manager -c awx-manager --tail=200 2>&1 | tail -200 || \
   sudo k3s kubectl logs -n '"$NS"' -l control-plane=controller-manager --tail=200 2>&1 | tail -200'
capg guest-awx-web-logs.txt  'sudo k3s kubectl logs -n '"$NS"' -l app.kubernetes.io/component=awx-web --tail=120 --all-containers 2>&1 | tail -200'
capg guest-awx-task-logs.txt 'sudo k3s kubectl logs -n '"$NS"' -l app.kubernetes.io/component=awx-task --tail=120 --all-containers 2>&1 | tail -200'
capg guest-postgres-logs.txt 'sudo k3s kubectl logs -n '"$NS"' -l app.kubernetes.io/component=database --tail=120 2>&1 | tail -200'
capg guest-migration.txt     'sudo k3s kubectl get jobs -n '"$NS"'; echo; sudo k3s kubectl logs -n '"$NS"' -l app.kubernetes.io/component=migration --tail=80 2>&1 | tail -120 || true'
capg guest-imagepull.txt     "$(kc get events -A) 2>&1 | grep -iE 'pull|backoff|errimage|failed' | tail -60 || echo none"
capg guest-pvc.txt           "$(kc get pvc -n "$NS" -o wide); echo; $(kc get pv)"

# ---- AWX HTTP (redact auth headers) ---------------------------------------
port="$(discover_host_port "${VER_NODEPORT:-30080}" 2>/dev/null || true)"
if [[ -n "$port" ]]; then
  { echo "### \$ curl -i http://127.0.0.1:${port}/api/v2/ping/";
    curl -sS -i -m 10 "http://127.0.0.1:${port}/api/v2/ping/" 2>&1; } \
    | sed -E 's/(Authorization|Set-Cookie|Cookie):.*/\1: [REDACTED]/I' > "${OUT}/awx-http-ping.txt" || true
fi

# ---- Final safety sweep: ensure no obvious secret leaked into the bundle ---
grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY' "$OUT" 2>/dev/null | while read -r leak; do
  log_warn "scrubbing private key found in ${leak}"; redact < "$leak" > "${leak}.tmp" && mv "${leak}.tmp" "$leak"
done

log_ok "Diagnostics collected: ${OUT}"
echo "$OUT"
