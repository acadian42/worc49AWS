# CLAUDE.md — guidance for AI agents working on this project

This directory is a **repeatable, idempotent installer** that stands up AWX inside a
throwaway Ubuntu 24.04 VM and exposes it on the host at `http://127.0.0.1:<port>/`.

## Architecture (do not change the hypervisor)

```
Linux host -> .venv (Ansible) -> Vagrant -> vmware_desktop -> VMware Workstation
 -> Ubuntu 24.04 VM -> K3s (single node) -> AWX Operator -> AWX + PostgreSQL
 -> guest NodePort 30080 -> Vagrant forward (127.0.0.1) -> AWX on host
```

* **VMware Workstation is the ONLY hypervisor.** Never add/fallback to VirtualBox,
  libvirt, QEMU, Hyper-V, etc.
* **Vagrant only manages the VM lifecycle.** All meaningful guest provisioning is done by
  **Ansible run from the host** (`playbooks/site.yml`, roles `common` -> `k3s` -> `awx`).
* Run `vagrant` commands **only from this directory**. Never touch the sibling `../testVM`
  or any VMware VM not created by this project.

## Hard rules

* Never commit secrets. Generated secrets live in `.state/` (gitignored, mode 0600).
* No floating image tags (`latest`/`main`/`devel`). Pin everything in `versions.yml`.
* No `curl | sh`. Download -> verify checksum -> execute.
* `operator 2.19.1` ships a broken `gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0` (HTTP 404).
  It is replaced by a **digest-pinned** `quay.io/brancz/kube-rbac-proxy` via Kustomize
  (`roles/awx/templates/kustomization.yaml.j2`). Do not remove this override.
* Treat a `Completed` migration **Job** as success, not a failed pod.
* VMware health = `vmmon`/`vmnet` loaded + `vmware-networks --status`; do NOT rely on
  `systemctl is-active vmware.service` (it can report a stale `failed`).

## Where things live

* Pins / single source of truth: `versions.yml` (+ live refresh `scripts/resolve-versions.sh`).
* Host preflight + dependency install: `scripts/bootstrap-host.sh`.
* Shared shell helpers (logging, retry, sudo keepalive, redaction): `scripts/lib/common.sh`.
* Entry points: `install.sh`, `status.sh`, `test.sh`, `diagnose.sh`, `destroy.sh`.
* Decisions & rationale: `docs/decisions.md`. Test evidence: `docs/test-results.md`.

## Encode every fix

Any manual repair discovered while debugging MUST be encoded into a script, role, or the
Vagrantfile. A hand-patched VM does not count — the next `destroy` + `install` must reproduce it.
