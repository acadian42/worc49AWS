# Architecture Decision Records

Concise records of the non-obvious choices. Versions verified live on 2026-06-24.

## ADR-001: Host detection accepts Ubuntu *and* Linux Mint

**Context.** The brief specifies a "Linux Mint host," but the actual build host reports
`ID=ubuntu`, `VERSION_ID=24.04` (noble) via `/etc/os-release`. Linux Mint is itself a
noble-based derivative (`ID=linuxmint`, `ID_LIKE` includes `ubuntu`/`debian`).

**Decision.** `bootstrap-host.sh` accepts `ID` in {`ubuntu`, `linuxmint`} (or `ID_LIKE`
containing `ubuntu`/`debian`) and derives the upstream codename from `UBUNTU_CODENAME`
(falling back to `VERSION_CODENAME`). It warns, but does not fail, on other Debian-like hosts.

**Consequence.** Works on the real Ubuntu host and on Mint without change.

## ADR-002: VMware health is judged by modules + networks, not the service unit

**Context.** On the build host, `vmmon`/`vmnet` are loaded and `vmware-networks --status`
reports all networks running, yet `systemctl is-active vmware.service` returns a **stale
`failed`** recorded at a boot *before* the modules were rebuilt for kernel 6.17.

**Decision.** Preflight treats VMware as healthy when (a) `vmware -v` works, (b) `vmmon` and
`vmnet` are in `lsmod`, and (c) `vmware-networks --status` reports running. It will
`systemctl restart vmware.service` to clear stale state, but does not gate on the unit's
prior status. Module (re)build via `vmware-modconfig --console --install-all` is attempted
only if modules are absent, with a documented `mkubecek/vmware-host-modules` fallback, and a
single exact corrective message if it still fails.

## ADR-003: K3s pinned to v1.35.5+k3s1 (Kubernetes 1.35)

**Context.** The newest tagged `awx-operator` release is **2.19.1** (2024-07-02; cadence has
stalled — nothing newer is tagged as of 2026-06-24). K3s `stable` is `v1.35.5+k3s1`, `latest`
is `v1.36.1+k3s1`. The operator predates k8s 1.35.

**Decision.** Pin K3s `stable` = **v1.35.5+k3s1**. Rationale:
* AWX and the operator use only GA APIs (Deployment/StatefulSet/Job/Service/PVC/Secret) that
  exist unchanged in 1.35, so the version skew is low-risk and is **validated empirically** by
  the integration tests (operator Available, AWX CR reconciled, API auth).
* Every **non-EOL** Kubernetes minor is newer than the operator regardless of choice:
  1.33 EOLs ~2026-06 (i.e. now → avoided), 1.34 ~2026-10, 1.35 ~2027-02, 1.36 ~2027-04.
  Picking `stable` (1.35) over bleeding-edge `latest` (1.36) follows "prefer stable, tagged."
* If AWX fails to reconcile for a Kubernetes-API reason, the installer descends the matrix
  `v1.35.5 → v1.34.9 → v1.33.5` and records the newest passing version. A version is never
  silently EOL: the chosen value and its support window are written to `docs/test-results.md`.

## ADR-004: kube-rbac-proxy replaced by a digest-pinned upstream image

**Context.** `awx-operator` 2.19.1's `config/default/manager_auth_proxy_patch.yaml` references
`gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0`. That image now returns **HTTP 404** (the
kubebuilder GCR path was discontinued), guaranteeing `ImagePullBackOff` on the operator pod's
sidecar, which keeps the operator Deployment from becoming Available.

**Options considered.**
1. A newer operator release that fixes it — **none exists** (2.19.1 is newest).
2. The ansible-community Helm chart — changes the install method away from the chosen Kustomize
   flow and still needs an image override.
3. A local Kustomize `images:` replacement to the upstream-maintained image, pinned by digest.

**Decision.** Option 3. Replace with **`quay.io/brancz/kube-rbac-proxy`** (brancz is the
upstream author/maintainer of kube-rbac-proxy), tag **v0.22.0**, pinned by digest
**`sha256:53d5a3911ac0…8850`** (multi-arch index digest, resolved live from the quay.io API by
`resolve-versions.sh`). This keeps the project on the Kustomize path, uses no arbitrary mirror,
and avoids any floating tag. The override lives in `roles/awx/templates/kustomization.yaml.j2`.

## ADR-005: kubectl-on-guest instead of the kubernetes.core collection

**Context.** "Prefer Ansible built-in modules and avoid unnecessary collections."

**Decision.** All Kubernetes actions render manifests with `ansible.builtin.template` and apply
them with `kubectl` (run on the guest via `ansible.builtin.command`) using prechecks plus
`changed_when`/`failed_when`, and wait with `kubectl wait`/`rollout status`. This removes the
need for `kubernetes.core` and the `kubernetes` Python library on the control node. `kubectl
apply` is declarative, so reruns are no-ops. `requirements.yml` is therefore empty.

## ADR-007: Full clone instead of linked clone (VMware Player mode)

**Context.** With `linked_clone = true`, `vagrant up` failed: the vmware_desktop
plugin invoked `vmrun -T player snapshot <box>.vmx …` and VMware returned
`Error: The operation is not supported`. On this host the Vagrant VMware Utility
drives `vmrun` in **Player** mode (`-T player`), and Player cannot create the
snapshot that a linked clone is built from.

**Decision.** Set `v.linked_clone = false` in the Vagrantfile. A full clone copies
the box's VMX/VMDK files directly (no snapshot/`vmrun` clone), so it works in Player
mode. The box's disk is thin/growable, so the full clone is still thinly
provisioned; the only cost is a one-time multi-GB copy at VM creation (the host has
ample disk). This keeps VMware Workstation as the sole hypervisor and needs no
licensing change.

## ADR-006: AWX images pinned (no floating tags)

**Decision.** The AWX CR sets `image_version: 24.6.1` explicitly (the version the operator
bundles) and lets the operator default the rest to that pinned version. The operator image is
pinned to `quay.io/ansible/awx-operator:2.19.1`. No `latest`/`main`/`devel` tags are deployed.
