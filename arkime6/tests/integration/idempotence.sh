#!/usr/bin/env bash
# ============================================================================
# idempotence.sh — prove site.yml is a true no-op on the second run.
#
# Runs playbooks/site.yml twice against the Vagrant lab inventory and FAILS if
# the SECOND run reports any 'changed=' > 0 in the play recap, or if any host
# is unreachable/failed on either run. A converged automation must reach a
# fixed point: the first run may change things, the second must change nothing.
#
# Usage:   tests/integration/idempotence.sh [extra ansible-playbook args...]
# Exit:    0 = idempotent, 1 = changes on second run, 2 = run error.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INVENTORY="${INVENTORY:-${REPO_ROOT}/inventories/vagrant/hosts.yml}"
PLAYBOOK="${PLAYBOOK:-${REPO_ROOT}/playbooks/site.yml}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/tests/.artifacts}"

mkdir -p "${LOG_DIR}"

FIRST_LOG="${LOG_DIR}/idempotence-run1.log"
SECOND_LOG="${LOG_DIR}/idempotence-run2.log"
# Any extra args (e.g. --limit, -e) are forwarded verbatim to ansible-playbook.
extra_args=("$@")

echo "Inventory: ${INVENTORY}"
echo "Playbook : ${PLAYBOOK}"

# ---- First (converging) run -------------------------------------------------
echo "==> Run 1 (converge)"
if ! ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" "${extra_args[@]}" \
      2>&1 | tee "${FIRST_LOG}"; then
  echo "FAIL: first run did not complete successfully." >&2
  exit 2
fi

# ---- Second (must be no-op) run --------------------------------------------
echo "==> Run 2 (must be a no-op)"
if ! ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" "${extra_args[@]}" \
      2>&1 | tee "${SECOND_LOG}"; then
  echo "FAIL: second run did not complete successfully." >&2
  exit 2
fi

# ---- Parse the PLAY RECAP of the SECOND run --------------------------------
# Recap lines look like:
#   es-phys-01 : ok=42 changed=0 unreachable=0 failed=0 skipped=7 rescued=0 ignored=0
changed_total=0
bad=0

while read -r line; do
  case "${line}" in
    *"changed="*)
      host="${line%% *}"
      changed="$(printf '%s\n' "${line}" | grep -oE 'changed=[0-9]+' | grep -oE '[0-9]+')"
      unreachable="$(printf '%s\n' "${line}" | grep -oE 'unreachable=[0-9]+' | grep -oE '[0-9]+')"
      failed="$(printf '%s\n' "${line}" | grep -oE 'failed=[0-9]+' | grep -oE '[0-9]+')"
      changed_total=$(( changed_total + changed ))
      if [ "${changed}" -ne 0 ] || [ "${unreachable}" -ne 0 ] || [ "${failed}" -ne 0 ]; then
        echo "NON-IDEMPOTENT: ${host} changed=${changed} unreachable=${unreachable} failed=${failed}" >&2
        bad=1
      else
        echo "OK: ${host} changed=0 unreachable=0 failed=0"
      fi
      ;;
  esac
done < "${SECOND_LOG}"

if [ "${bad}" -ne 0 ]; then
  echo "FAIL: second run reported changed=${changed_total} (expected 0). Not idempotent." >&2
  echo "Inspect the tasks marked 'changed' in ${SECOND_LOG}." >&2
  exit 1
fi

echo "PASS: second run reported changed=0 on every host. Playbook is idempotent."
exit 0
