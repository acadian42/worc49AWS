#!/usr/bin/env bash
# Make the locally-built custom EE available to the AWX VM's K3s containerd.
# NARROWLY-SCOPED change to the AWX VM: imports ONE image into containerd
# (k8s.io namespace). Does not reconfigure AWX/K3s, restart services, or touch
# any other VM. Re-runnable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$(cd "$ROOT/.." && pwd)/ansible_AWX_installer"
IMG="${E2E_EE_IMAGE:-fpc-e2e-ee:1.0}"
TAR="$ROOT/.e2e-state/fpc-e2e-ee.tar"

echo "[1/4] docker save $IMG"
docker save "$IMG" -o "$TAR"
ls -lh "$TAR"

echo "[2/4] upload to AWX VM"
cd "$INSTALLER"
vagrant upload "$TAR" /tmp/fpc-e2e-ee.tar ansible-awx-ubuntu24

echo "[3/4] import into k3s containerd (k8s.io namespace)"
vagrant ssh ansible-awx-ubuntu24 -c "sudo k3s ctr -n k8s.io images import /tmp/fpc-e2e-ee.tar && rm -f /tmp/fpc-e2e-ee.tar" 2>/dev/null

echo "[4/4] verify image present in k3s"
vagrant ssh ansible-awx-ubuntu24 -c "sudo k3s ctr -n k8s.io images ls | grep -i fpc-e2e-ee || echo 'NOT FOUND'" 2>/dev/null | tr -d '\r'
rm -f "$TAR"
echo "done."
