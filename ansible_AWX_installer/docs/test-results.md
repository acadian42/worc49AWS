# Test Results

> This file is updated by the build. It records the exact commands run, the versions that were
> actually installed, and the pass/fail outcome of each acceptance check. No secrets are stored here.

## Environment (build host)

| Item | Value |
|---|---|
| Date | 2026-06-24 |
| Host OS | Ubuntu 24.04.4 LTS (noble) |
| Arch / CPU | x86_64 / AMD Ryzen 9 9950X3D (32 vCPU, AMD-V) |
| RAM / Disk free | 60 GiB / 2.4 TiB |
| VMware Workstation | 25.0.1 (build 25219725) |
| Vagrant | 2.4.9 |

## Resolved versions actually used

Verified live by `scripts/resolve-versions.sh` on 2026-06-24 — every pin matched
upstream exactly (operator/k3s/utility/plugin/box/proxy-digest all `MATCH? yes`).

| Component | Version |
|---|---|
| vagrant-vmware-utility | 1.0.24 (deb SHA256 verified) |
| vagrant-vmware-desktop plugin | 3.0.5 |
| Box | bento/ubuntu-24.04 202510.26.0 (vmware_desktop) |
| ansible-core | 2.18.6 (ansible-lint 24.12.2, yamllint 1.35.1) |
| K3s | v1.35.5+k3s1 (Kubernetes 1.35.5) |
| AWX Operator | 2.19.1 |
| AWX | 24.6.1 |
| kube-rbac-proxy (override) | quay.io/brancz/kube-rbac-proxy:v0.22.0@sha256:53d5a3911ac0…8850 |
| PostgreSQL | quay.io/sclorg/postgresql-15-c9s:20260617 |
| Redis | docker.io/redis:7.4.9 |

## Static tests — PASS (7/7, 2026-06-24)

| Check | Result |
|---|---|
| shellcheck (14 scripts) | PASS |
| ansible-playbook --syntax-check | PASS |
| ansible-lint | PASS |
| yamllint | PASS |
| YAML manifest validation | PASS |
| vagrant validate | PASS |
| no secrets in tracked/doc files | PASS |

## Live integration tests (15) — PASS 15/15 (first install, 2026-06-24 14:14)

| # | Check | Result |
|---|---|---|
| 1 | Provider is vmware_desktop | PASS |
| 2 | Guest is Ubuntu 24.04 | PASS |
| 3 | Ansible ping | PASS |
| 4 | K3s service active | PASS |
| 5 | Node Ready (`v1.35.5+k3s1`) | PASS |
| 6 | local-path storage provisions a PVC | PASS |
| 7 | AWX Operator Deployment Available | PASS |
| 8 | AWX CR reconciled (Running=True) | PASS |
| 9 | PostgreSQL PVC Bound | PASS |
| 10 | AWX web (3/3) + task (4/4) Ready | PASS |
| 11 | NodePort service on 30080 | PASS |
| 12 | Host forwarded port discovered (30080) | PASS |
| 13 | Host GET /api/v2/ping/ == 200 (AWX 24.6.1) | PASS |
| 14 | Authenticated GET /api/v2/me/ == 200 (admin) | PASS |
| 15 | status.sh reports healthy | PASS |

Migration job: `awx-migration-24.6.1` succeeded=1 (Completed treated as success).
First install PLAY RECAP: `ok=46 changed=17 unreachable=0 failed=0`.

## Idempotence (second install) — PASS (2026-06-24 14:15)

Second `./install.sh` exited 0. Second-run PLAY RECAP: **`ok=37 changed=0`** (true no-op).
- VM was NOT recreated (same VMware machine id)
- admin password unchanged; secret key unchanged
- AWX still reachable (`/api/v2/ping/` 200), credentials intact

## Clean destroy + rebuild — PASS (2026-06-24 14:16–14:22)

1. `./destroy.sh --yes` — VM stopped + deleted; `.state/` secrets preserved.
2. `./install.sh` — fresh `vagrant up` (full clone) + full provision, exit 0.
   - New VM id `061cf095-…` (old was `2b306ffb-…`) → VM genuinely recreated.
   - Admin password hash identical before/after (`acd57f9e…`) → credentials reused
     from `.state/`; in-cluster Secrets recreated from those files.
   - Host `/api/v2/ping/` 200 (AWX 24.6.1); authenticated `/api/v2/me/` 200 (admin).
3. `./tests/integration.sh` — **15/15 passed, 0 failed** on the rebuilt environment.

## Secrets / diagnostics safety — PASS

- Static secret scan: no generated secret value or private key in any tracked/doc file.
- `./diagnose.sh` bundle (30 files): admin password and secret key NOT present; K8s
  secrets captured as names/types only (no `DATA`), auth headers/`Opaque`/keys `[REDACTED]`.

## Result

| Acceptance gate | Result |
|---|---|
| Static tests | PASS (7/7) |
| First install + 15 live tests | PASS (15/15) |
| Idempotence (second install, changed=0) | PASS |
| Clean destroy + rebuild + 15 live tests | PASS (15/15) |
| Secrets not exposed | PASS |

## Commands run (chronological highlights)

1. `./scripts/bootstrap-host.sh` — installed utility 1.0.24 (SHA256 verified), plugin 3.0.5, venv (ansible-core 2.18.6)
2. `./scripts/resolve-versions.sh` — all pins matched upstream live
3. `./tests/static.sh` — 7/7 pass
4. `./install.sh` — first full install, exit 0, AWX reachable on http://127.0.0.1:30080/
5. `./tests/integration.sh` — 15/15 pass
