# ansible_AWX_installer

A repeatable, idempotent, **host-side** installer that stands up [AWX](https://github.com/ansible/awx)
(the open-source Ansible controller / web UI / API) inside a disposable Ubuntu 24.04 VM and exposes it
on your host at `http://127.0.0.1:<port>/`.

```
Linux host → .venv (Ansible) → Vagrant → vmware_desktop → VMware Workstation
 → Ubuntu 24.04 VM → K3s → AWX Operator → AWX + PostgreSQL
 → guest NodePort 30080 → Vagrant forward (127.0.0.1) → AWX in your browser
```

VMware Workstation is the **only** hypervisor used. Vagrant only manages the VM lifecycle; all the
real guest configuration is done by **Ansible running from the host**.

---

## Prerequisites

These must already be present on the host (the installer verifies them and stops with one clear
instruction if a hard prerequisite is missing):

| Requirement | Why | Auto-installed? |
|---|---|---|
| **x86_64** Linux (Ubuntu 24.04 or Linux Mint, noble-based) | Build/control host | n/a |
| **VMware Workstation 17.5+** (tested on 25.0.1) with working `vmmon`/`vmnet` modules | The hypervisor | **No** — licensed install; the installer verifies & can rebuild modules, but cannot perform a Broadcom-authenticated install |
| **Vagrant 2.4+** (tested on 2.4.9) | VM lifecycle | No (verified; install from HashiCorp apt repo if absent) |
| `sudo` access | Install host packages, manage modules/services | The run asks once and caches the timestamp |
| Internet access | Pull box, K3s, operator, images | n/a |
| ≥ 4 vCPU, ≥ 8 GiB free RAM, ≥ 40 GiB free disk | Run the VM | n/a |

Everything else (the **Vagrant VMware Utility**, the **`vagrant-vmware-desktop`** plugin, a project-local
**Python venv with Ansible**, `shellcheck`, `jq`, …) is installed automatically by the bootstrap step.

---

## One-command installation

```bash
cd ansible_AWX_installer
./install.sh
```

`install.sh` performs, in order: host preflight + dependency install → live version resolution →
`vagrant up` → inventory generation → Ansible provisioning (K3s + AWX) → AWX API/login validation →
prints the result. It is safe to re-run (see **Idempotence**). On failure it automatically writes a
redacted diagnostic bundle under `.artifacts/<timestamp>/` and exits non-zero.

On success it prints something like:

```
AWX is ready.
  URL:       http://127.0.0.1:30080/
  Username:  admin
  Password:  stored at .state/awx_admin_password (mode 0600)
  Reveal it: cat .state/awx_admin_password
```

---

## Status, health, and login

```bash
./status.sh        # Vagrant/VM, K3s, operator, pods, services, storage, AWX URL + API status
```

Log in at the printed URL with username **`admin`**. Retrieve the password with:

```bash
cat .state/awx_admin_password
```

(The password is generated once, stored only under `.state/` at mode `0600`, and never printed in
routine logs or committed to git.)

---

## Configuration overrides

Copy `.env.example` to `.env` and edit (sourced by `install.sh`). Common knobs:

| Variable | Default | Meaning |
|---|---|---|
| `AWX_VM_CPUS` | `4` | VM vCPUs |
| `AWX_VM_MEM` | `8192` | VM RAM (MB) |
| `AWX_HOST_PORT` | `30080` | Preferred host port (auto-corrected if busy) |
| `AWX_BOX_VERSION` | pinned in `versions.yml` | Box version |
| `AWX_ALLOW_VERSION_DRIFT` | `0` | Allow `resolve-versions.sh` to bump pins when upstream moves |
| `AWX_OFFLINE` | `0` | Skip live version resolution; use `versions.yml` as-is |

All component versions are pinned in **`versions.yml`** (single source of truth). The CPU/RAM env vars
are also honored directly by the `Vagrantfile`.

---

## Update policy

* Versions are **pinned** in `versions.yml` and verified live by `scripts/resolve-versions.sh`.
  By default the pins win; set `AWX_ALLOW_VERSION_DRIFT=1` to let the resolver propose newer values.
* To move to a new K3s/operator/AWX/box version: edit `versions.yml`, run `./scripts/resolve-versions.sh`
  to sanity-check availability, then `./destroy.sh --yes && ./install.sh` for a clean rebuild.
* The `kube-rbac-proxy` replacement image is **digest-pinned**; if you change its tag, re-resolve the
  digest (the resolver does this automatically from the quay.io API).
* No floating tags (`latest`/`main`/`devel`) are ever deployed.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| Install failed | Look in `.artifacts/<timestamp>/` (auto-collected, secrets redacted), or run `./diagnose.sh` |
| `vmmon`/`vmnet` missing or `vmware.service` failed | The bootstrap rebuilds modules via `vmware-modconfig`; if your kernel is too new it prints the exact `mkubecek/vmware-host-modules` remediation |
| AWX pod `ImagePullBackOff` on `kube-rbac-proxy` | The Kustomize override should prevent this; confirm `versions.yml` has the `quay.io/brancz` digest and re-run |
| Host port 30080 busy | Vagrant auto-corrects; the real port is shown by `./status.sh` and `vagrant port` |
| AWX migration pod shows `Completed` and looks "failed" | That is success — a finished one-shot Job, not a crash |
| Want full live checks | `./test.sh` (static + integration) |

Diagnostics never include passwords, tokens, private keys, secret data, or kubeconfig credentials.

---

## Cleanup

```bash
./destroy.sh --yes     # destroys ONLY this project's VM (ansible-awx-ubuntu24)
```

This removes the Vagrant VM but **keeps** your generated secrets in `.state/` so a later
`./install.sh` reuses the same admin credentials. To wipe everything including secrets:

```bash
./destroy.sh --yes && rm -rf .state .cache .artifacts inventory/generated/hosts.ini
```

`destroy.sh` only ever touches the VM defined by this project's `Vagrantfile`; it never affects other
VMware VMs.

---

## Repository layout

See `docs/architecture.md` for the full diagram and `docs/decisions.md` for why each version/approach
was chosen. Key paths: `Vagrantfile`, `playbooks/site.yml`, `roles/{common,k3s,awx}`, `scripts/`,
`tests/`, `versions.yml`.
