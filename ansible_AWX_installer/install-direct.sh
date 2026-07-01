#!/usr/bin/env bash
# =============================================================================
# install-direct.sh — install AWX DIRECTLY on THIS Ubuntu 24 host.
#
# Unlike install.sh (which uses Vagrant + VMware Workstation to create a
# throwaway nested VM), this wrapper provisions AWX onto the machine it runs on:
#
#   this host -> .venv (Ansible, connection=local) -> K3s -> AWX Operator
#             -> AWX + PostgreSQL -> NodePort 30080 on this host's own IP
#
# It reuses the SAME guest-agnostic Ansible roles (common -> k3s -> awx) and the
# SAME pinned versions (versions.yml). No Vagrant, no VMware, no nested virt.
#
# Idempotent: safe to re-run. Secrets are generated once and preserved.
#
# Env overrides (or put them in .env, which is sourced):
#   AWX_AUTO_K3S_FALLBACK=1   descend the K3s compatibility matrix on failure
#   AWX_OPEN_FIREWALL=1       `ufw allow <nodeport>/tcp` if ufw is active
#   AWX_ALLOW_VERSION_DRIFT=0 (see load_versions in scripts/lib/common.sh)
#   NO_COLOR / typical CI knobs honored by common.sh
# =============================================================================
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"   # (re)sets PROJECT_DIR to the same path

INVENTORY_FILE="${PROJECT_DIR}/inventory/local.ini"

direct_on_error() {
  log_error "Direct install failed."
  log_error "Re-run ./install-direct.sh after fixing the reported error."
  log_error "Guest state: 'sudo k3s kubectl -n awx get pods' (once K3s is up) shows AWX pod status."
}
setup_err_trap direct_on_error

# ---- optional .env ---------------------------------------------------------
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  log_info "Sourcing .env overrides"
  set -a; # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"; set +a
fi

mkdir -p "$STATE_DIR" "$CACHE_DIR" "$ARTIFACTS_DIR"
load_versions

# ---------------------------------------------------------------------------
# Connectivity helpers — a fresh VM often lacks curl, which must NOT be
# misreported as "no internet". Ensure probe tools exist, then probe robustly.
# ---------------------------------------------------------------------------
ensure_base_tools() {
  # curl + ca-certificates for downloads/probing; openssl for secret generation.
  local want=(curl ca-certificates openssl) missing=() p
  for p in "${want[@]}"; do
    case "$p" in
      curl)    have_cmd curl    || missing+=("$p") ;;
      openssl) have_cmd openssl || missing+=("$p") ;;
      *)       dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p") ;;
    esac
  done
  if (( ${#missing[@]} == 0 )); then
    log_ok "Base tools present (curl, ca-certificates, openssl)."
    return 0
  fi
  log_warn "Installing missing base tools: ${missing[*]}"
  sudo_init
  sudo apt-get update -qq || log_warn "apt-get update failed (offline/proxy?); continuing to probe."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
    || log_warn "Could not apt-install ${missing[*]}; will probe with wget//dev/tcp fallback."
}

# net_probe URL -> 0 if reachable. Tries curl, then wget, then a raw TCP :443,
# so it works even before curl is installed.
net_probe() {
  local url="$1" host
  host="${url#*://}"; host="${host%%/*}"
  if have_cmd curl; then curl -fsS -m 10 -o /dev/null "$url" 2>/dev/null && return 0; fi
  if have_cmd wget; then wget -q -T 10 -O /dev/null "$url" 2>/dev/null && return 0; fi
  timeout 10 bash -c "exec 3<>/dev/tcp/${host}/443" 2>/dev/null && return 0
  return 1
}

# ---------------------------------------------------------------------------
# 1. Preflight — validate THIS host (not a hypervisor; no vmx/svm needed).
# ---------------------------------------------------------------------------
preflight_local() {
  log_step "Preflight: this host (OS / arch / resources / systemd / internet)"

  [[ -r /etc/os-release ]] || die "/etc/os-release not readable"
  # shellcheck disable=SC1091
  . /etc/os-release
  local id="${ID:-}" like="${ID_LIKE:-}" ver="${VERSION_ID:-0}"
  if [[ "$id" == "ubuntu" || "$id" == "linuxmint" || "$like" == *ubuntu* || "$like" == *debian* ]]; then
    log_ok "Host is ${PRETTY_NAME:-$id}"
  else
    log_warn "Host ID='${id}' is not Ubuntu/Mint/Debian; the roles assume apt + Ubuntu >= 24.04."
  fi
  # roles/common hard-asserts Ubuntu >= 24.04; fail fast here with a clear message.
  if [[ "$id" == "ubuntu" ]]; then
    awk -v v="$ver" 'BEGIN{exit !(v+0 >= 24.04)}' \
      || blocker "roles/common requires Ubuntu >= 24.04; this host reports ${ver}."
    log_ok "Ubuntu ${ver} satisfies the >= 24.04 requirement."
  fi

  local arch; arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || blocker "AWX/K3s images here are amd64; this host is '${arch}'."
  log_ok "Architecture: x86_64 (amd64)"

  # systemd is required by K3s and the roles (systemd units, sysctl --system).
  [[ -d /run/systemd/system ]] || blocker "systemd not detected (/run/systemd/system missing). K3s requires systemd."
  log_ok "systemd present."

  # Resources: '/' free space is a HARD role assert (>= 20 GiB). CPU/RAM are
  # advisory here (AWX + K3s + PostgreSQL realistically want >= 4 vCPU / 8 GiB).
  local root_free_gb; root_free_gb="$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"");print $1}')"
  (( root_free_gb >= 20 )) || blocker "roles/common needs >= 20 GiB free on '/'; have ${root_free_gb} GiB."
  (( root_free_gb >= 40 )) || log_warn "Only ${root_free_gb} GiB free on '/'; 40+ GiB recommended for images."
  log_ok "Disk: ${root_free_gb} GiB free on '/'."

  local cpus; cpus="$(nproc)"
  (( cpus >= 4 )) || log_warn "Only ${cpus} vCPU; AWX+K3s want >= 4. Continuing (may be slow/unstable)."
  local mem_mb; mem_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  (( mem_mb >= 8000 )) || log_warn "Only ${mem_mb} MB RAM; AWX+K3s want >= 8 GiB. Continuing (may OOM)."
  log_ok "Resources: ${cpus} vCPU / ${mem_mb} MB RAM."

  # Internet: this host pulls K3s + the awx-operator base + images. Make sure the
  # probe tools exist first, or a missing curl looks like "no internet".
  ensure_base_tools
  log_step "Preflight: internet reachability (from this host)"
  local crit_ok=0 u
  for u in https://get.k3s.io https://github.com; do
    if net_probe "$u"; then
      log_ok "reachable: ${u}"; crit_ok=$((crit_ok+1))
    else
      log_warn "NOT reachable: ${u}"
    fi
  done
  if (( crit_ok == 0 )); then
    log_error "Probe tools available: curl=$(have_cmd curl && echo yes || echo NO), wget=$(have_cmd wget && echo yes || echo NO)"
    if getent hosts get.k3s.io >/dev/null 2>&1; then
      log_error "DNS for get.k3s.io RESOLVES -> connectivity/proxy/firewall issue, not DNS."
    else
      log_error "DNS for get.k3s.io does NOT resolve -> check /etc/resolv.conf or your proxy."
    fi
    blocker "Cannot reach get.k3s.io or github.com from this host.
If you use an HTTP proxy, export http_proxy/https_proxy before re-running
(and also configure it for apt, K3s, and containerd, which pull images later)."
  fi
  if net_probe https://quay.io; then
    log_ok "reachable: https://quay.io (image registry)"
  else
    log_warn "quay.io not reachable now; image pulls may fail later."
  fi
}

# ---------------------------------------------------------------------------
# 2. Control environment — project .venv with pinned Ansible (no collections).
# ---------------------------------------------------------------------------
setup_venv() {
  log_step "Control env: project Python venv (${VENV_DIR})"
  if ! have_cmd python3; then blocker "python3 not found. Install it: sudo apt-get install -y python3"; fi
  # `python3 -m venv` needs the python3-venv package on Ubuntu.
  if ! python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
    log_warn "python3-venv/ensurepip missing; installing it (sudo)..."
    sudo_init
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv
  fi
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "${VENV_DIR}"; log_ok "Created venv."
  else
    log_ok "venv already exists."
  fi
  log_info "Installing pinned control deps (ansible-core, jmespath; lint tools optional)..."
  "${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip wheel
  "${VENV_DIR}/bin/python" -m pip install --quiet -r "${PROJECT_DIR}/requirements.txt"
  local acore; acore="$("${VENV_DIR}/bin/ansible" --version 2>/dev/null | head -1 || true)"
  [[ -n "$acore" ]] || die "ansible failed to install into venv"
  log_ok "Ansible ready: ${acore}"
  # requirements.yml is `collections: []` — nothing to install from Galaxy.
}

# ---------------------------------------------------------------------------
# 3. Secrets — generate once, preserve forever (identical to install.sh).
# ---------------------------------------------------------------------------
ensure_secret() {
  local file="$1" gen="$2"
  [[ -s "$file" ]] && return 0
  log_info "Generating secret: $(basename "$file")"
  ( umask 077; eval "$gen" > "$file" ); chmod 0600 "$file"
}
prepare_secrets() {
  log_step "Secrets"
  require_cmd openssl
  ensure_secret "${STATE_DIR}/awx_admin_password" "openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32"
  ensure_secret "${STATE_DIR}/awx_secret_key"     "openssl rand -hex 32"
  chmod 0600 "${STATE_DIR}/awx_admin_password" "${STATE_DIR}/awx_secret_key"
  log_ok "Admin password + secret key present under .state/ (mode 0600)."
}

# ---------------------------------------------------------------------------
# 4. Static local inventory — replaces generate-inventory.sh (vagrant ssh-config).
#    connection=local: the play's `awx_vm` host IS this machine.
# ---------------------------------------------------------------------------
write_inventory() {
  log_step "Inventory: static local (connection=local)"
  mkdir -p "$(dirname "$INVENTORY_FILE")"
  umask 077
  cat > "$INVENTORY_FILE" <<EOF
# Generated by install-direct.sh — targets THIS host (no Vagrant).
[awx_vm]
localhost ansible_connection=local

[awx_vm:vars]
ansible_python_interpreter=/usr/bin/python3
EOF
  log_ok "Wrote ${INVENTORY_FILE}"
}

# ---------------------------------------------------------------------------
# 5. Provision — Ansible (K3s + AWX) with the descending K3s fallback matrix.
#    Mirrors install.sh::provision but local, and uninstalls K3s locally between
#    attempts (no `vagrant ssh`).
# ---------------------------------------------------------------------------
run_ansible() {
  local kver="$1"
  "${VENV_DIR}/bin/ansible-playbook" -i "$INVENTORY_FILE" playbooks/site.yml \
    -e "k3s_version_override=${kver}" -e "awx_state_dir=${STATE_DIR}"
}
provision() {
  # sudo now, so Ansible become (sudo -n) uses the cached/kept-alive credential.
  sudo_init

  log_step "Ansible connectivity preflight (local)"
  "${VENV_DIR}/bin/ansible" -i "$INVENTORY_FILE" awx_vm -m ping -o \
    || die "Ansible cannot reach localhost via connection=local (unexpected)."
  log_ok "Ansible ping OK."

  local candidates=("$VER_K3S") v chosen=""
  while read -r v; do [[ -n "$v" ]] && candidates+=("$v"); done < <(vget_list k3s.fallback_versions)
  local last="${candidates[${#candidates[@]}-1]}"
  for v in "${candidates[@]}"; do
    log_step "Provisioning this host with K3s ${v}"
    if run_ansible "$v"; then chosen="$v"; break; fi
    log_warn "Provisioning failed with K3s ${v}."
    [[ "${AWX_AUTO_K3S_FALLBACK:-1}" == "1" ]] || break
    if [[ "$v" != "$last" ]]; then
      log_warn "Descending compatibility matrix: uninstalling K3s and retrying with next version."
      sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
    fi
  done
  [[ -n "$chosen" ]] || die "AWX did not come up on any K3s version in the matrix: ${candidates[*]}"
  echo "$chosen" > "${CACHE_DIR}/k3s_chosen.txt"
  log_ok "Provisioned successfully with K3s ${chosen}."
}

# ---------------------------------------------------------------------------
# 6. Firewall — NodePort is bound on 0.0.0.0; open it if ufw is active.
# ---------------------------------------------------------------------------
open_firewall() {
  [[ "${AWX_OPEN_FIREWALL:-1}" == "1" ]] || return 0
  have_cmd ufw || return 0
  sudo ufw status 2>/dev/null | grep -qi '^Status: active' || return 0
  log_step "Firewall: allowing NodePort ${VER_NODEPORT}/tcp (ufw is active)"
  if sudo ufw allow "${VER_NODEPORT}/tcp" >/dev/null 2>&1; then
    log_ok "ufw now allows ${VER_NODEPORT}/tcp."
  else
    log_warn "Could not add ufw rule; open ${VER_NODEPORT}/tcp manually if the UI is unreachable."
  fi
}

# ---------------------------------------------------------------------------
# 7. Validate + result.
# ---------------------------------------------------------------------------
primary_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' \
    || hostname -I 2>/dev/null | awk '{print $1}'
}
validate_and_report() {
  local ip; ip="$(primary_ip)"; [[ -n "$ip" ]] || ip="127.0.0.1"
  local url="http://${ip}:${VER_NODEPORT}/"
  echo "$url" > "${CACHE_DIR}/awx_url.txt" 2>/dev/null || true

  log_step "Validate: AWX HTTP reachability (may take a minute after rollout)"
  if retry 12 5 curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${VER_NODEPORT}/"; then
    log_ok "AWX responds on 127.0.0.1:${VER_NODEPORT}."
  else
    log_warn "AWX not answering yet on :${VER_NODEPORT}. It may still be starting."
    log_warn "Check: sudo k3s kubectl -n ${VER_NAMESPACE} get pods"
  fi

  cat <<EOF

${C_GRN}${C_BOLD}==================== AWX is ready ====================${C_RESET}
  URL (this host):   http://127.0.0.1:${VER_NODEPORT}/
  URL (from network): ${url}
  Username:  ${VER_ADMIN_USER}
  Password:  stored at .state/awx_admin_password (mode 0600)
  Reveal it: cat ${PROJECT_DIR}/.state/awx_admin_password

  Pods:      sudo k3s kubectl -n ${VER_NAMESPACE} get pods
  Uninstall: sudo /usr/local/bin/k3s-uninstall.sh   (removes K3s + AWX; keeps .state/)
${C_GRN}${C_BOLD}=====================================================${C_RESET}
EOF
}

main() {
  log_step "AWX DIRECT installer starting (host-local, no Vagrant/VMware) — project: ${PROJECT_DIR}"
  preflight_local
  setup_venv
  prepare_secrets
  write_inventory
  provision
  open_firewall
  validate_and_report
  log_ok "Direct install complete."
}
main "$@"
