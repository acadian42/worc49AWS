#!/usr/bin/env bash
# Clean-rebuild reproducibility proof: destroy ONLY the two E2E VMs, recreate
# them from clean Vagrant state, re-discover IPs, re-sync AWX, run the full AWX
# deployment workflow, and re-run the verification suites.
# Touches ONLY fpc-e2e-* VMs and FPC-E2E AWX objects.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VENV="$ROOT/.lintvenv/bin/activate"; [ -f "$VENV" ] && . "$VENV"

echo "== [1/7] destroy ONLY the two E2E VMs =="
( cd vagrant/e2e_smoke && VAGRANT_DEFAULT_PROVIDER=vmware_desktop vagrant destroy -f )

echo "== [2/7] recreate the VMs from clean state =="
( cd vagrant/e2e_smoke && VAGRANT_DEFAULT_PROVIDER=vmware_desktop vagrant up )

echo "== [3/7] re-discover NAT IPs + write host_vars =="
bash tests/e2e/discover_ips.sh

echo "== [4/7] commit refreshed host_vars (IPs may change) =="
git add -A
git commit -q -m "E2E: refresh discovered VM IPs after clean rebuild

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" || echo "(no IP changes to commit)"
git rev-parse HEAD | tee .e2e-state/commit_sha.txt

echo "== [5/7] re-sync AWX project + inventory source =="
python tests/e2e/resync.py

echo "== [6/7] run the full AWX deployment workflow =="
python tests/e2e/awx_launch.py wf "FPC-E2E Workflow"

echo "== [7/7] re-run verification suites =="
bash tests/e2e/verify.sh
bash tests/e2e/arkime_ingest_check.sh
bash tests/e2e/auth_login_check.sh
echo "CLEAN REBUILD COMPLETE."
