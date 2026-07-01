#!/usr/bin/env bash
# =============================================================================
# install.sh — one-command AWX installer.
#
# host preflight + deps -> resolve versions -> vagrant up -> inventory ->
# Ansible (K3s + AWX) -> validate API + login -> print result.
#
# Idempotent: safe to re-run. On failure: auto-collect redacted diagnostics.
# =============================================================================
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"

install_on_error() {
  log_error "Installation failed."
  log_info  "Auto-collecting diagnostics (secrets redacted)..."
  local d; d="$("${PROJECT_DIR}/scripts/collect-diagnostics.sh" 2>/dev/null | tail -1 || true)"
  [[ -n "$d" ]] && log_error "Diagnostic bundle: ${d}"
  log_error "Inspect with ./status.sh or ./diagnose.sh, fix, then re-run ./install.sh"
}
setup_err_trap install_on_error

# ---- optional .env ---------------------------------------------------------
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  log_info "Sourcing .env overrides"
  set -a; # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"; set +a
fi

mkdir -p "$STATE_DIR" "$CACHE_DIR" "$ARTIFACTS_DIR"
load_versions

# ---- secrets (generate once; preserve forever) -----------------------------
ensure_secret() {
  local file="$1" gen="$2"
  if [[ -s "$file" ]]; then return 0; fi
  log_info "Generating secret: $(basename "$file")"
  ( umask 077; eval "$gen" > "$file" )
  chmod 0600 "$file"
}
prepare_secrets() {
  log_step "Secrets"
  ensure_secret "${STATE_DIR}/awx_admin_password" "openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32"
  ensure_secret "${STATE_DIR}/awx_secret_key"     "openssl rand -hex 32"
  chmod 0600 "${STATE_DIR}/awx_admin_password" "${STATE_DIR}/awx_secret_key"
  log_ok "Admin password + secret key present under .state/ (mode 0600)."
}

# ---- VM lifecycle ----------------------------------------------------------
vm_up() {
  log_step "VM: vagrant up (provider vmware_desktop)"
  local st; st="$(vm_state || true)"
  if [[ "$st" == "running" ]]; then
    log_ok "VM already running; reusing it (no recreate)."
  else
    log_info "Bringing up VM (state: ${st:-absent})..."
    ( cd "$PROJECT_DIR" && retry 2 5 vagrant up --provider vmware_desktop )
    log_ok "VM is up."
  fi
}

# ---- Ansible provisioning with descending K3s compatibility matrix ---------
run_ansible() {
  local kver="$1"
  ( cd "$PROJECT_DIR" && "${VENV_DIR}/bin/ansible-playbook" playbooks/site.yml \
      -e "k3s_version_override=${kver}" -e "awx_state_dir=${STATE_DIR}" )
}
provision() {
  "${PROJECT_DIR}/scripts/generate-inventory.sh"
  # Preflight: fail fast on connection/config errors instead of burning the
  # whole K3s fallback matrix on a non-provisioning problem. If SSH is briefly
  # unreachable (VMware NAT warm-up), restart networking once and retry.
  log_step "Ansible connectivity preflight"
  if ! ( cd "$PROJECT_DIR" && "${VENV_DIR}/bin/ansible" awx_vm -m ping -o ); then
    log_warn "Guest unreachable; ensuring VMware networking is up and retrying..."
    sudo vmware-networks --start >/dev/null 2>&1 || true
    sudo systemctl is-active --quiet vmware.service || sudo systemctl restart vmware.service >/dev/null 2>&1 || true
    "${PROJECT_DIR}/scripts/generate-inventory.sh" >/dev/null 2>&1 || true
    retry 6 5 bash -c "cd '$PROJECT_DIR' && '${VENV_DIR}/bin/ansible' awx_vm -m ping -o" \
      || die "Ansible cannot reach the guest after restarting VMware networking."
  fi
  log_ok "Ansible ping OK."
  local candidates=("$VER_K3S") v chosen=""
  while read -r v; do [[ -n "$v" ]] && candidates+=("$v"); done < <(vget_list k3s.fallback_versions)
  local last="${candidates[${#candidates[@]}-1]}"
  for v in "${candidates[@]}"; do
    log_step "Provisioning guest with K3s ${v}"
    if run_ansible "$v"; then chosen="$v"; break; fi
    log_warn "Provisioning failed with K3s ${v}."
    [[ "${AWX_AUTO_K3S_FALLBACK:-1}" == "1" ]] || break
    if [[ "$v" != "$last" ]]; then
      log_warn "Descending compatibility matrix: uninstalling K3s in guest and retrying with next version."
      ( cd "$PROJECT_DIR" && vagrant ssh -c 'sudo /usr/local/bin/k3s-uninstall.sh' 2>/dev/null ) || true
    fi
  done
  [[ -n "$chosen" ]] || die "AWX did not come up on any K3s version in the matrix: ${candidates[*]}"
  echo "$chosen" > "${CACHE_DIR}/k3s_chosen.txt"
  log_ok "Guest provisioned successfully with K3s ${chosen}."
}

print_result() {
  local url; url="$(cat "${CACHE_DIR}/awx_url.txt" 2>/dev/null || echo "http://127.0.0.1:${VER_NODEPORT}/")"
  cat <<EOF

${C_GRN}${C_BOLD}==================== AWX is ready ====================${C_RESET}
  URL:       ${url}/
  Username:  ${VER_ADMIN_USER}
  Password:  stored at .state/awx_admin_password (mode 0600)
  Reveal it: cat ${PROJECT_DIR}/.state/awx_admin_password

  Status:    ./status.sh
  Tests:     ./test.sh
  Diagnose:  ./diagnose.sh
  Cleanup:   ./destroy.sh --yes
${C_GRN}${C_BOLD}=====================================================${C_RESET}
EOF
}

main() {
  log_step "AWX installer starting (project: ${PROJECT_DIR})"
  prepare_secrets
  "${PROJECT_DIR}/scripts/bootstrap-host.sh"
  "${PROJECT_DIR}/scripts/resolve-versions.sh" || log_warn "version resolution had issues; continuing with pins."
  vm_up
  provision
  "${PROJECT_DIR}/scripts/validate-awx.sh"
  print_result
  log_ok "Install complete."
}
main "$@"
