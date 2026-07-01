#!/usr/bin/env bash
# =============================================================================
# status.sh — report Vagrant/VM, K3s, AWX operator, pods, services, storage,
# the AWX URL, and live API status. Exit 0 only if the install looks healthy.
# =============================================================================
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"
load_versions
NS="${VER_NAMESPACE}"
HEALTHY=1

gssh() { ( cd "$PROJECT_DIR" && vagrant ssh -c "$1" ) 2>/dev/null; }
section() { printf '\n%s%s── %s ──%s\n' "$C_BOLD" "$C_CYN" "$1" "$C_RESET"; }

section "Vagrant / VM"
st="$(vm_state || echo absent)"
printf '  VM state: %s\n' "$st"
[[ "$st" == "running" ]] || { log_error "VM is not running"; HEALTHY=0; }
( cd "$PROJECT_DIR" && vagrant port 2>/dev/null | sed 's/^/  /' ) || true

if [[ "$st" == "running" ]]; then
  section "Provider"
  if ls -d "${PROJECT_DIR}"/.vagrant/machines/*/vmware_desktop >/dev/null 2>&1; then
    log_ok "provider is vmware_desktop"
  else
    log_error "provider is not vmware_desktop"; HEALTHY=0
  fi

  section "Guest OS"
  os="$(gssh 'grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d \"')"
  printf '  %s\n' "${os:-unknown}"
  [[ "$os" == *"24.04"* ]] || { log_error "guest is not Ubuntu 24.04"; HEALTHY=0; }

  section "K3s"
  k3s_active="$(gssh 'systemctl is-active k3s' 2>/dev/null)"
  [[ "$k3s_active" == active ]] && log_ok "k3s service active" || { log_error "k3s service not active"; HEALTHY=0; }
  node="$(gssh 'sudo k3s kubectl get nodes --no-headers' 2>/dev/null)"
  printf '  node: %s\n' "${node:-<none>}"
  if grep -qw Ready <<<"$node"; then log_ok "node Ready"; else log_error "node not Ready"; HEALTHY=0; fi
  printf '%s\n' "$(gssh 'sudo k3s kubectl get storageclass' 2>/dev/null)" | sed 's/^/  /'

  section "AWX Operator"
  op_avail="$(gssh "sudo k3s kubectl -n ${NS} get deploy awx-operator-controller-manager -o jsonpath='{.status.availableReplicas}'" 2>/dev/null)"
  if [[ "$op_avail" =~ ^[1-9] ]]; then log_ok "operator Deployment Available"; else log_error "operator Deployment not Available"; HEALTHY=0; fi

  section "AWX workloads (ns: ${NS})"
  printf '%s\n' "$(gssh "sudo k3s kubectl -n ${NS} get pods -o wide" 2>/dev/null)" | sed 's/^/  /'
  section "Services"
  printf '%s\n' "$(gssh "sudo k3s kubectl -n ${NS} get svc" 2>/dev/null)" | sed 's/^/  /'
  nodeports="$(gssh "sudo k3s kubectl -n ${NS} get svc -o jsonpath='{.items[*].spec.ports[*].nodePort}'" 2>/dev/null)"
  if grep -qw "${VER_NODEPORT}" <<<"$nodeports"; then log_ok "NodePort ${VER_NODEPORT} present"; else log_error "NodePort ${VER_NODEPORT} not found"; HEALTHY=0; fi
  section "Storage"
  printf '%s\n' "$(gssh "sudo k3s kubectl -n ${NS} get pvc" 2>/dev/null)" | sed 's/^/  /'
  pvc_phases="$(gssh "sudo k3s kubectl -n ${NS} get pvc -o jsonpath='{.items[*].status.phase}'" 2>/dev/null)"
  if grep -qw Bound <<<"$pvc_phases"; then log_ok "PVC Bound"; else log_warn "no Bound PVC yet"; fi
fi

section "AWX endpoint"
port="$(discover_host_port "${VER_NODEPORT}" 2>/dev/null || true)"
if [[ -n "$port" ]]; then
  url="http://127.0.0.1:${port}"
  printf '  URL: %s/\n' "$url"
  code="$(curl -fsS -m 8 -o /dev/null -w '%{http_code}' "${url}/api/v2/ping/" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then log_ok "/api/v2/ping/ -> 200"; else log_error "/api/v2/ping/ -> ${code}"; HEALTHY=0; fi
else
  log_error "could not discover forwarded host port"; HEALTHY=0
fi

section "Summary"
if (( HEALTHY == 1 )); then
  log_ok "AWX installation looks HEALTHY."
  echo "  Username: ${VER_ADMIN_USER}   Password: cat .state/awx_admin_password"
  exit 0
else
  log_error "AWX installation is NOT fully healthy (see above). Try ./diagnose.sh"
  exit 1
fi
