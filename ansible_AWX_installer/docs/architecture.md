# Architecture

## Overview

`ansible_AWX_installer` builds a complete, disposable AWX environment and exposes it on the
host's loopback interface. The host is only lightly touched (Vagrant plugin + VMware utility +
a project-local Python venv); everything heavy lives inside a Vagrant-managed VM.

```
┌────────────────────────────── Linux host (Ubuntu/Mint, x86_64) ──────────────────────────────┐
│                                                                                               │
│  install.sh                                                                                   │
│    ├── scripts/bootstrap-host.sh   (preflight + deps: utility, plugin, venv, shellcheck)      │
│    ├── scripts/resolve-versions.sh (live version/digest resolution -> .cache)                 │
│    ├── .venv/ (ansible-core)  ──── ansible-playbook ─────────────────┐                        │
│    ├── Vagrant ── vmware_desktop ── VMware Workstation 25.x          │ (SSH, from host)        │
│    │                                                                 │                        │
│    └── scripts/validate-awx.sh (curl 127.0.0.1:<port>/api/v2/...)    │                        │
│                                                                      ▼                        │
│   ┌────────────────────────── VM: ansible-awx-ubuntu24 (Ubuntu 24.04) ──────────────────────┐ │
│   │  role common : swap off, kernel modules/sysctls, time sync, disk assert                 │ │
│   │  role k3s    : K3s v1.35.5+k3s1 (traefik+servicelb disabled, local-path kept)           │ │
│   │  role awx    : awx-operator 2.19.1 (kustomize) + AWX 24.6.1 CR + operator PostgreSQL     │ │
│   │                                                                                          │ │
│   │     Service awx-service  type=NodePort  nodePort=30080  ◄── kube-rbac-proxy override     │ │
│   └──────────────────────────────────────┬───────────────────────────────────────────────┘ │
│                                           │ guest tcp/30080                                   │
│        Vagrant forwarded_port (auto_correct) │  bound to 127.0.0.1                            │
│                                           ▼                                                   │
│                       http://127.0.0.1:<discovered host port>/                                │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

## Component responsibilities

| Layer | Tool | Responsibility |
|---|---|---|
| Host preflight | `bootstrap-host.sh` | Detect OS/arch/resources/virt; verify VMware modules+networks; install Vagrant VMware Utility (checksum-verified) + `vagrant-vmware-desktop` plugin; create `.venv`; install apt essentials |
| Version control | `resolve-versions.sh` | Query GitHub/k3s/HashiCorp/quay APIs; resolve the kube-rbac-proxy digest; write `.cache/versions.resolved.yml` |
| VM lifecycle | `Vagrantfile` + Vagrant | Create/boot/forward/destroy ONLY this VM; pin box+version; NodePort forward to loopback |
| Inventory | `generate-inventory.sh` | Convert `vagrant ssh-config` -> `inventory/generated/hosts.ini` (no hardcoded port/key) |
| Guest config | Ansible `common` | Ubuntu assert, swap off, `overlay`/`br_netfilter`, sysctls, inotify, time sync, disk assert |
| Kubernetes | Ansible `k3s` | Install pinned K3s (download+verify, not `curl\|sh`); disable Traefik/ServiceLB; wait Ready |
| AWX | Ansible `awx` | Secrets, operator kustomize (+ proxy digest override), AWX CR (NodePort 30080), wait healthy |
| Validation | `validate-awx.sh` | Discover host port; `GET /api/v2/ping/`; authenticated `GET /api/v2/me/` |

## Networking

* Guest exposes AWX through a Kubernetes **NodePort** service on **30080**.
* Vagrant forwards guest `30080` to host `127.0.0.1:30080` with `auto_correct: true`. If 30080 is
  taken on the host, Vagrant picks another port; the real port is discovered at runtime with
  `vagrant port` (never assumed).
* K3s ServiceLB (klipper-lb) and Traefik are disabled — NodePort is the single, predictable path,
  and disabling ServiceLB avoids it grabbing host ports inside the guest.
* The Kubernetes API (6443) is **not** forwarded to the host.

## Idempotency model

* **VM**: reused if already running; never recreated by a rerun.
* **Secrets**: generated once into `.state/`, reused forever; the K8s Secrets are recreated from
  those files only if missing.
* **K3s**: install skipped when the running version already equals the pin.
* **Operator/AWX**: applied with `kubectl apply` (declarative; no-op when unchanged).
* **Waits**: explicit `kubectl wait` / `rollout status` with bounded timeouts and visible polling,
  not blind `sleep`s.
