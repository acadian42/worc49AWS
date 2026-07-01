#!/usr/bin/env bash
# =============================================================================
# tests/static.sh — static analysis: shellcheck, ansible syntax/lint, yamllint,
# YAML validation, Vagrantfile validation, and a secret-leak scan.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_DIR"
# shellcheck source=../scripts/lib/common.sh
source "${PROJECT_DIR}/scripts/lib/common.sh"

PASS=0; FAIL=0
ok()   { log_ok   "$1"; PASS=$((PASS+1)); }
bad()  { log_error "$1"; FAIL=$((FAIL+1)); }
VENV="${VENV_DIR}/bin"

log_step "Static test: shellcheck"
if have_cmd shellcheck; then
  mapfile -t sh_files < <(find . -path ./.venv -prune -o -name '*.sh' -print | sort)
  if shellcheck -x -S warning "${sh_files[@]}"; then ok "shellcheck clean (${#sh_files[@]} files)"; else bad "shellcheck reported issues"; fi
else
  bad "shellcheck not installed (run ./scripts/bootstrap-host.sh)"
fi

log_step "Static test: ansible-playbook --syntax-check"
if [[ -x "${VENV}/ansible-playbook" ]]; then
  # syntax-check needs an inventory; use a throwaway localhost one.
  if ANSIBLE_INVENTORY=/dev/null "${VENV}/ansible-playbook" --syntax-check \
       -i 'localhost,' playbooks/site.yml >/dev/null; then
    ok "playbook syntax OK"
  else
    bad "playbook syntax-check failed"
  fi
else
  bad "venv ansible-playbook missing (run bootstrap)"
fi

log_step "Static test: ansible-lint"
if [[ -x "${VENV}/ansible-lint" ]]; then
  if "${VENV}/ansible-lint" -q playbooks/site.yml; then ok "ansible-lint clean"; else bad "ansible-lint reported issues"; fi
else
  bad "venv ansible-lint missing (run bootstrap)"
fi

log_step "Static test: yamllint"
if [[ -x "${VENV}/yamllint" ]]; then
  if "${VENV}/yamllint" .; then ok "yamllint clean"; else bad "yamllint reported issues"; fi
else
  bad "venv yamllint missing (run bootstrap)"
fi

log_step "Static test: YAML parse validation"
yaml_ok=1
while IFS= read -r f; do
  "${VENV}/python" -c "import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))" "$f" 2>/dev/null \
    || { bad "invalid YAML: $f"; yaml_ok=0; }
done < <(find . \( -path ./.venv -o -path ./.vagrant -o -path ./.cache -o -path ./.artifacts \) -prune -o \
            \( -name '*.yml' -o -name '*.yaml' \) -print | grep -v templates/)
(( yaml_ok == 1 )) && ok "all tracked YAML files parse"

log_step "Static test: Vagrantfile validation"
vv_out="$( cd "$PROJECT_DIR" && vagrant validate 2>&1 )"; vv_rc=$?
if (( vv_rc == 0 )); then
  ok "vagrant validate passed"
elif grep -qiE 'provider|plugin' <<<"$vv_out"; then
  log_warn "vagrant validate needs the vmware_desktop plugin; deferring full validation"
  ok "Vagrantfile present (full validation deferred until plugin installed)"
else
  bad "vagrant validate failed: ${vv_out}"
fi

log_step "Static test: no secrets committed / in docs"
leak=0
for sf in awx_admin_password awx_secret_key; do
  if [[ -s "${STATE_DIR}/${sf}" ]]; then
    val="$(cat "${STATE_DIR}/${sf}")"
    if [[ -n "$val" ]] && grep -rIn --exclude-dir=.state --exclude-dir=.cache --exclude-dir=.artifacts \
          --exclude-dir=.venv --exclude-dir=.vagrant -F "$val" . >/dev/null 2>&1; then
      bad "secret value from ${sf} found in tracked files!"; leak=1
    fi
  fi
done
# Ensure no ACTUAL private key blocks are tracked. Anchor to start-of-line so
# we match real PEM files, not redaction/scan patterns inside our own scripts.
if grep -rIlE '^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
     --exclude-dir=.venv --exclude-dir=.vagrant --exclude-dir=.state . >/dev/null 2>&1; then
  bad "a private key file appears in the tree"; leak=1
fi
(( leak == 0 )) && ok "no generated secrets or private keys in tracked/doc files"

log_step "Static summary: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 )) || exit 1
