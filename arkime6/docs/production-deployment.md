# FPC Arkime — Production Deployment Runbook

> Authoritative production deployment runbook for the FPC Arkime full-packet-capture (FPC) cluster.
> Every path, playbook, role, variable, AWX object, and command in this document comes from the
> repository at the root of this tree. Where the lab (`inventories/e2e`) uses a reduced value, the
> production value is stated explicitly and the reversal is called out.
>
> Conventions used in this document:
> - **🔴 DESTRUCTIVE** — the step closes/overwrites/recreates data or indices. Read the rollback boundary first.
> - **🟡 APPROVAL GATE** — the step is gated behind an AWX manual approval node (24 h timeout) and/or an explicit `-e` flag.
> - **LAB → PROD** — a value that differs between `inventories/e2e` and `inventories/production`; the production value is mandatory.

---

## 0. Audience, scope, and what this deploys

### 0.1 Audience

Infrastructure / platform engineers operating the production data-center deployment of the FPC Arkime
cluster through the existing AWX controller. Familiarity with Ansible, Docker Compose v2, Elasticsearch,
Arkime, and Active Directory / LDAPS is assumed.

### 0.2 What this deploys

A full-packet-capture platform composed of two physical tiers, deployed and operated entirely through
AWX against a custom Execution Environment. There is **no fork in role/playbook logic between lab and
production** — the only differences are inventory values. The production `group_vars` shipped in the
repo already contain the correct production defaults; the lab reductions live only under
`inventories/e2e/group_vars`.

| Tier | Inventory group | Hosts | Per host |
|---|---|---|---|
| Elasticsearch | `elasticsearch_physical_hosts` | `es-phys-01` … `es-phys-05` (5) | 125 GiB RAM; **3–5 ES node containers** derived by Ansible (not inventory hosts) |
| Arkime recorders | `arkime_recorders` | `arkime-rec-01` … `arkime-rec-05` (5) | Arkime Capture + Viewer (`fpc-arkime`) and Nginx + LDAP-auth sidecar (`fpc-nginx`) |

Both groups are children of `all_fpc_hosts`. ES node containers are **derived** by the
`elasticsearch_cluster` role from `elasticsearch_nodes_per_host`; their names are
`<physical_host>-node-NN` (e.g. `es-phys-01-node-01`). At the default density of 3 that is **15 ES
nodes** total (4 → 20, 5 → 25).

Identity is **Active Directory over LDAPS**; TLS for the ES mesh and Nginx is provided by the **FPC
Internal CA** (or your enterprise CA for the public Nginx cert — see §3).

### 0.3 Component matrix (topology recap)

```
                         Active Directory / LDAPS (636)
                                    ^
                                    | LDAP bind (service acct)
          analyst_cidrs            |
   browser ──443/TLS──► fpc-nginx ─┴─ fpc-ldap-auth (caltechads, loopback:8888)
                          │  auth_request /check-auth
                          │  proxy → 127.0.0.1:8005
                          ▼
                     arkime-viewer (loopback only, userAuthIps 127.0.0.1/32)
                     arkime-capture ──► writes pcap to /fpc/arkime6/pcap
                          │
                          │ arkime_writer / HTTPS :9200 (multi-seed CSV, all 5 ES hosts)
                          ▼
            es-phys-01..05  ×  3–5  ES node containers each  (cluster fpc-es)
                          shard-awareness attr = physical_host
                          3 master-eligible nodes (es-phys-01/02/03 node-01)
```

### 0.4 Version pins (verified 2026-06-24)

| Component | Repo / image | Version | Digest status (production `group_vars/all.yml`) |
|---|---|---|---|
| Arkime | `ghcr.io/arkime/arkime/arkime` | `v6.5.0` | **Pinned**: `sha256:083fc1af41bcad021eeb6b9cc630e26adae35690106d35e5193e4e8442895c66` |
| Elasticsearch | `docker.elastic.co/elasticsearch/elasticsearch` | `8.19.17` | **EMPTY / CHANGEME** — `es_image_digest` must be resolved & pinned |
| Nginx | `nginx` | `1.27-alpine` | **EMPTY / CHANGEME** — `nginx_image_digest` must be resolved & pinned |
| LDAP-auth sidecar | `caltechads/nginx-ldap-auth-service` | `2.6.2` | **EMPTY / CHANGEME** — `ldap_auth_image_digest` must be resolved & pinned |
| Control plane | `ansible-core` | `2.21.1` | EE-pinned |
| Control plane | `community.docker` | `5.2.1` | EE + root `requirements.yml` |
| Control plane | `awx.awx` | `24.6.1` | EE + root `requirements.yml` |
| On-host | Docker Compose plugin | `>= 2.18.0` | `docker_compose_min_version`, asserted by `docker_engine` role |

**Image construction rule:** `<x>_image = repo + (':' + version  if  digest == ''  else  '@' + digest)`.
An empty digest silently resolves to a **moving tag**, not a pinned image. Three of four images ship
empty in production — resolving them is a mandatory step (§5).

---

## 1. Pre-requisites & responsibilities checklist

Complete every row before launching any AWX job. Each is a hard precondition asserted or assumed downstream.

| # | Item | Owner | Detail / where consumed |
|---|---|---|---|
| 1 | 5 ES physical hosts, 125 GiB RAM each | DC / Compute | preflight asserts `ansible_memtotal_mb >= 2048` and per-container RAM floor |
| 2 | 5 Arkime recorder hosts | DC / Compute | capture + viewer + nginx |
| 3 | OS = **Ubuntu 24.04 (noble)** primary, or **Rocky 9** secondary | OS team | preflight asserts `ansible_distribution`/version in `supported_os_matrix` |
| 4 | Dedicated NVMe/SSD block device per ES host for ES data | Storage | `es_data_devices` (e.g. `['/dev/nvme0n1']`); preflight asserts `stat.exists` and `stat.isblk` |
| 5 | Large/fast disk for `/fpc` (esp. `/fpc/arkime6/pcap`) on recorders | Storage | sized for `arkime_pcap_retention_days` + free-space watermark |
| 6 | Measured **physical core count** per host | Compute | `host_cpu_cores`; preflight asserts `capture_threads <= host_cpu_cores` |
| 7 | Real **management NIC** and **capture/SPAN/TAP NIC** names per recorder | Network | `management_interface`, `capture_interfaces`; preflight asserts both in `ansible_interfaces` |
| 8 | Management IP per host, routable from AWX | Network | `management_ip`; drives ES seed/publish, all API URLs, cert IP SAN, firewall peer list |
| 9 | Per-recorder analyst-facing **FQDN** with forward DNS | Network / DNS | `nginx_server_name` (e.g. `rec01.fpc.example.com`); cert CN/SAN + analyst URL |
| 10 | Internal **DNS** servers; each host's `inventory_hostname` resolves | DNS | `dns_servers`; preflight `getent ahosts inventory_hostname` must succeed |
| 11 | Internal **NTP** servers reachable | Time | `ntp_servers`; preflight `getent ahosts <server>` per entry; `chrony_max_offset_seconds: 1` |
| 12 | **Control-plane subnet** (AWX / SSH) and **analyst subnet** | Network / Security | `control_plane_cidrs`, `analyst_cidrs` drive the firewall matrix |
| 13 | **SSH host keys** of all 10 hosts known/accepted to AWX EE | Platform | `ansible.cfg` sets `host_key_checking=True` — unknown keys fail the connection |
| 14 | SSH automation account with passwordless sudo (`become_method: sudo`) | Platform | `ansible_user` (default `ansible`); `become` is per-play |
| 15 | **AD service account** (read-only) for the LDAP bind | Identity | `ldap_bind_dn` + `vault_ldap_bind_password` |
| 16 | AD groups for sign-in populated with `memberOf` | Identity | `ldap_authorization_filter` gates on `memberOf` of `arkime_user_ldap_groups` (static groups header). `arkime_admin_ldap_group` is **not consumed at runtime** — admin is granted out-of-band at init (`arkime_add_user.sh --admin`); see §6.5 |
| 17 | **AD LDAPS CA** PEM staged on each recorder at `ldap_ca_file` | Identity / PKI | default `/fpc/arkime6/ssl/ad-ca.pem`; dirname bind-mounted to `/certs` in the sidecar. **No automation stages or checks this file** — operator must copy it and prove the bind/CA manually (§6.6) before Stage 5, else the sidecar crash-loops (defect 17) |
| 18 | **Internal CA** material (or enterprise cert for Nginx) | PKI | `internal_ca_enabled: true` (default); see §3 |
| 19 | **AWX controller** reachable, with valid TLS; admin/token | Platform | `fpc_controller_host`, `CONTROLLER_PASSWORD` env |
| 20 | **Build host** with Docker + `docker buildx` + `ansible-builder` | Platform | EE build + image save/ship (§5); no role does the `docker save` step |
| 21 | Private registry (optional) if not using `load_from_archive` | Platform | `registry_url`, `registry_username`, `vault_registry_password` |

> **NTP/DNS note:** preflight only *probes resolution*; it does not configure servers. Set
> `ntp_servers` and `dns_servers` to real internal values in `group_vars/all.yml` (defaults are RFC5737
> placeholders). The `common` role configures chrony from `ntp_servers`.
>
> **Preflight scope caveat:** `preflight.yml` validates **host-local facts + NTP/DNS resolution ONLY**
> (OS matrix, RAM, ES block devices, ES per-container RAM, NICs, `capture_threads ≤ cores`, NTP
> `getent`, DNS `getent inventory_hostname`). It does **NOT** verify any inter-tier / firewall
> reachability — e.g. AWX→target SSH (22), recorder→ES (9200/9300), analyst→Nginx (443/80), or the
> private registry (when `image_delivery_mode=registry`). Those routing/firewall assumptions are
> unverified until the relevant stage fails. **Confirm them manually** before deploy, e.g.:
>
> ```bash
> nc -vz es-phys-01 9200        # from a recorder: recorder→ES HTTP
> nc -vz es-phys-01 9300        # ES peer transport
> nc -vz arkime-rec-01 443      # from an analyst subnet host: analyst→Nginx
> # from AWX/EE: ssh reachability to every host:22; `docker login <registry>` dry-run if registry mode
> ```

---

## 2. Inventory & host_vars

Nothing in git contains the production topology: `inventories/production/hosts.yml` and real
`host_vars/*.yml` are **gitignored**. Only `hosts.example.yml`, `host_vars/es-phys-01.yml.example`, and
`host_vars/.gitkeep` are committed. You must create the real files.

### 2.1 Create `hosts.yml`

```bash
cp inventories/production/hosts.example.yml inventories/production/hosts.yml
# edit inventories/production/hosts.yml — fill in real values for all 10 hosts
```

The group hierarchy is fixed: `all → all_fpc_hosts → { elasticsearch_physical_hosts, arkime_recorders }`.

### 2.2 Per-host key contract

| Key | Required on | Purpose | Production value |
|---|---|---|---|
| `ansible_host` | all 10 | SSH-reachable address AWX connects to | real mgmt IP/DNS (examples set `= management_ip`) |
| `management_ip` | all 10 | ES seed/publish, **all** ES/validation/backup/recover/upgrade API URLs `https://{{management_ip}}:9200`, cert IP SAN, firewall peer list | real mgmt IP per host |
| `physical_host` | all 10 | Failure-domain label: ES awareness attr, node-name prefix, master-eligibility key, cert CN/DNS, cert dir `pki/es/<physical_host>` | **= `inventory_hostname`** (`es-phys-01`…`05`, `arkime-rec-01`…`05`) |
| `es_data_devices` | ES hosts | Block device(s) for ES data; preflight asserts `isblk` | real NVMe/SSD, e.g. `['/dev/nvme0n1']` |
| `management_interface` | recorders | Mgmt NIC; preflight asserts present | real mgmt NIC name (default `eth0`) |
| `capture_interfaces` | recorders | Capture/SPAN/TAP NIC list; preflight asserts each present | real capture NIC list (default `['eth1']`) |
| `nginx_server_name` | recorders | Analyst-facing FQDN: cert CN/DNS SAN + auth validation URL | real per-recorder FQDN (group default `{{ inventory_hostname }}` is **not** acceptable) |

> **Gotcha (silent drop):** firewall peer extraction uses `select('defined')` on `management_ip`. A
> missing `management_ip` on any host silently drops that host from the allow-lists. Set it on every host.
>
> **Gotcha (silent data path):** `es_data_devices` defaults to `[]`, which **silently falls back to
> bind-mounted dirs on the root filesystem**. preflight only asserts the device when the list is
> non-empty, so an accidental empty list *passes* preflight and you get no dedicated ES storage.

### 2.3 Top-level connection vars (`all.vars` in `hosts.yml`)

```yaml
  vars:
    ansible_user: ansible                       # real SSH automation user (NOT vagrant)
    ansible_python_interpreter: /usr/bin/python3
```

### 2.4 Create per-host `host_vars`

Files are named `inventories/production/host_vars/<inventory_hostname>.yml` (gitignored).

```bash
cp inventories/production/host_vars/es-phys-01.yml.example \
   inventories/production/host_vars/es-phys-01.yml
# repeat for es-phys-02..05 and create arkime-rec-01..05.yml
```

ES host (`es-phys-NN.yml`):

```yaml
---
management_ip: 10.x.x.NN          # real
physical_host: es-phys-NN
es_data_devices:
  - /dev/nvme0n1                  # real dedicated device
host_cpu_cores: 32               # MEASURED physical cores (example shows 32)
```

Recorder host (`arkime-rec-NN.yml`) — minimum:

```yaml
---
management_ip: 10.x.x.NN
physical_host: arkime-rec-NN
host_cpu_cores: 32               # MEASURED; gates capture_threads
# management_interface / capture_interfaces / nginx_server_name may live here or in hosts.yml
```

> `host_cpu_cores` has a fallback (`ansible_processor_vcpus`) in the preflight assert, but it is
> treated as **required/measured** — vcpus on hyperthreaded hosts over-count cores and weaken the
> capture-sizing assertion. Always set the measured value.

---

## 3. Secrets & PKI

### 3.1 The complete `vault_*` secret list

Source of truth: `inventories/production/group_vars/vault.example.yml` (documentation only — see the
warning below). Generate strong, unique values. Arkime secrets must be high-entropy hex via
`openssl rand -hex 32`.

| Vault var | Maps to | Used for | Notes |
|---|---|---|---|
| `vault_registry_password` | `registry_password` | Private registry login | only if `image_delivery_mode: registry` |
| `vault_internal_ca_key_passphrase` | `internal_ca_key_passphrase` | Internal CA RSA-4096 key passphrase | **default is empty = UNENCRYPTED CA key** — set a real passphrase |
| `vault_es_bootstrap_password` | `es_bootstrap_password` | ES `elastic` superuser | used by all health/security/backup/upgrade/recover/validate API probes |
| `vault_es_arkime_writer_password` | `es_arkime_writer_password` **and** `arkime_es_password` | Least-privilege `arkime_writer` ES user | **must be non-empty** or `es_security.yml` is skipped and recorders get ES 401 |
| `vault_arkime_password_secret` | `arkime_password_secret` | Arkime `passwordSecret` | `openssl rand -hex 32`; identical across all 5 recorders |
| `vault_arkime_server_secret` | `arkime_server_secret` | Arkime `serverSecret` | `openssl rand -hex 32`; identical across all 5 recorders |
| `vault_arkime_admin_password` | `arkime_admin_password` | Arkime built-in `admin` (break-glass digest account) | strong value |
| `vault_ldap_bind_password` | `ldap_bind_password` | AD service-account bind password | rendered into `ldap-auth.env` (`LDAP_PASSWORD`) |
| `vault_ldap_auth_session_secret` | `ldap_auth_session_secret` | Sidecar `SECRET_KEY` (session) | high-entropy |
| `vault_ldap_auth_csrf_secret` *(NOT in vault.example.yml)* | `ldap_auth_csrf_secret` | Sidecar `CSRF_SECRET_KEY` | referenced in `roles/nginx_ldap_proxy/defaults/main.yml`; defaults to the session secret if unset — set a distinct value |

### 3.2 ⚠ Vault loading gotcha

`vault.example.yml`'s filename **intentionally does not match a group**, so Ansible will **not auto-load
it** even after you copy/encrypt it. If unloaded, every `vault_*` resolves to `''` via `| default('')`
and security/secrets **silently degrade**. Two correct channels:

**(a) Ansible Vault file (group-matching path):**

> **🛑 Mandatory directory conversion first.** Production ships `inventories/production/group_vars/all.yml`
> as a **single file**. Ansible does **not** allow a file `group_vars/all.yml` and a directory
> `group_vars/all/` to coexist for the same group — you must convert the file into the directory form
> before adding `vault.yml`. (The `e2e` inventory already uses the directory form:
> `group_vars/all/main.yml`.) Convert, then place `vault.yml` beside the converted file:

```bash
mkdir inventories/production/group_vars/all
git mv inventories/production/group_vars/all.yml inventories/production/group_vars/all/main.yml
cp inventories/production/group_vars/vault.example.yml inventories/production/group_vars/all/vault.yml
# fill in every CHANGEME_ value, then:
ansible-vault encrypt inventories/production/group_vars/all/vault.yml
# vault.yml is gitignored — NEVER commit it
```

> Both `all/main.yml` and `all/vault.yml` now resolve under the `all` group and load together. If you
> skip the conversion and drop `vault.yml` into a new `all/` dir while `all.yml` still exists, Ansible
> errors on the duplicate-group layout (or silently ignores one), leaving every `vault_*` unresolved —
> the exact silent-degradation failure this section warns about. **Channel (b) below (the AWX Vault
> credential) avoids this entirely and is the lower-risk path.**

**(b) AWX `FPC Ansible Vault` credential (preferred):** attach the Vault credential to every job
template (objects.yml does this by name); AWX decrypts at run time.

### 3.3 AWX custom credential types (and the wiring gap)

`awx/job_templates/objects.yml` creates two custom credential **types**:

- **`FPC LDAP Bind`** (kind `net`): fields `bind_dn`, `bind_password`(secret) → injects env `FPC_LDAP_BIND_DN`, `FPC_LDAP_BIND_PASSWORD`.
- **`FPC Container Registry`** (kind `cloud`): fields `registry_url`, `registry_username`, `registry_password`(secret) → injects env `FPC_REGISTRY_URL`, `FPC_REGISTRY_USERNAME`, `FPC_REGISTRY_PASSWORD`.

> **🛑 Wiring gap:** **No role or playbook reads those `FPC_*` env vars.** The roles consume the
> Ansible vars `ldap_bind_password` (← `vault_ldap_bind_password`) and `registry_*` (← `vault_registry_password`)
> from the **Vault**. So in practice the LDAP bind password and registry creds **must be in the Ansible
> Vault**; attaching the custom credential types alone does not wire the secrets. (Or add tasks that
> read `lookup('env','FPC_*')`.)

### 3.4 PKI model

**Internal CA (default, `internal_ca_enabled: true`):** the `common` role (`tasks/pki.yml`) creates the
CA **exactly once** on the control node (`delegate_to: localhost`, `run_once`) under
`{{ playbook_dir }}/../pki`:

- `ca.key.pem` — RSA 4096, mode `0600`, passphrase = `internal_ca_key_passphrase`.
- `ca.crt.pem` — self-signed, CN = `internal_ca_cn` (`FPC Internal CA`), validity `+{{ tls_cert_validity_days }}d` (825), mode `0644`.
- Public cert distributed to every host trust store (Debian `update-ca-certificates`, RHEL `update-ca-trust`).

The `elasticsearch_cluster` role signs **per-node** certs (RSA 2048) under `pki/es/<physical_host>/`
with SANs `DNS:<nodename>, DNS:<fqdn>, DNS:<physical_host>, DNS:localhost, IP:<management_ip>,
IP:127.0.0.1`, shipped to each node's `certs/` (`node.key.pem` 0640 owned `1000:1000`).

The `nginx_ldap_proxy` role signs the **public Nginx** cert (CN `nginx_server_name`, SANs
`DNS:nginx_server_name, DNS:inventory_hostname, IP:management_ip`) — **but only if no external cert
exists**.

**Enterprise PKI for the public Nginx cert (recommended for analyst browsers):** pre-stage your
enterprise/CA-signed cert + key on each recorder, and the role skips internal-CA signing:

```
{{arkime_base}}/ssl/cert.pem   →  /fpc/arkime6/ssl/cert.pem   (nginx_tls_cert)
{{arkime_base}}/ssl/key.pem    →  /fpc/arkime6/ssl/key.pem    (nginx_tls_key)
```

> The ES transport/HTTP certs are **always** internal-CA in this codebase — there is no external-CSR
> path for ES nodes. Internal CA self-signed Nginx certs will not be trusted by analyst browsers
> unless you distribute `pki/ca.crt.pem` to them.
>
> **Protect `pki/`:** the local `pki/` tree on the AWX EE / control node holds the CA private key **and
> every node private key**. It is gitignored, mode `0700`. Back it up and protect it — losing it means
> re-issuing all certs; leaking it compromises the whole mesh.

### 3.5 ES native-realm least-privilege user

`roles/elasticsearch_cluster/tasks/es_security.yml` (run_once, no_log, authed as `elastic` /
`es_bootstrap_password`) creates:

- Role **`arkime_writer`**: cluster `[monitor, manage_index_templates, manage_ilm]`; index `all` on `arkime_*`, `sessions3-*`, `history_*`, `.tasks`.
- User **`arkime_writer`** (password `es_arkime_writer_password`, roles `[arkime_writer]`).

Recorders authenticate to ES as `arkime_writer` (NOT the `elastic` superuser). **Gated on
`es_security_enabled` AND `es_arkime_writer_password` length > 0** — set `vault_es_arkime_writer_password`
or this is silently skipped.

---

## 4. Lab → production differences that MUST be set

> **Core principle:** all lab reductions live in `inventories/e2e/group_vars/*`. The shipped
> `inventories/production/group_vars/*` already contain correct production values. The single most
> important "reversal" is **use the production inventory, not the e2e inventory** (an inventory does not
> inherit another inventory's group_vars, so lab values do not leak — but you must select
> `FPC Production` in AWX). The table below lists everything that differs, so you can verify the
> production files and never copy a lab value across.

### 4.1 Critical reversal table

| Variable | LAB (e2e) value | **PRODUCTION value (required)** | Where (prod) |
|---|---|---|---|
| `es_http_tls` | `false` | **`true`** | es group_vars |
| `arkime_es_scheme` | `http` | **`https`** | arkime_recorders.yml |
| `es_index_replicas` | `0` | **`1`** | es group_vars |
| `es_master_eligible_hosts` | 1 host | **`[es-phys-01, es-phys-02, es-phys-03]`** (3 distinct domains) | es group_vars |
| `validation_expected_masters` | overridden to `1` | **`3`** (role default; do NOT override) | role default |
| `elasticsearch_nodes_per_host` | 3 (single host) | **3** (benchmarked; 3/4/5 → 15/20/25) | es group_vars / survey |
| `es_awareness_force_values` | single zone | **`es-phys-01,es-phys-02,es-phys-03,es-phys-04,es-phys-05`** (all 5) | es group_vars |
| `os_docker_reserve_gib` | `2` | **`13`** (for 125 GiB hosts) | es group_vars |
| `es_heap_max_gib` | `1` | **`26`** (compressed-oops ceiling) | es group_vars |
| `es_min_container_gib` | `2` | **`4`** (role default; do NOT override) | role default |
| `es_disk_watermark_flood` | `97%` | **`95%`** (low 85 / high 90 same) | es group_vars |
| `es_cluster_name` | `fpc-es-e2e` | **`fpc-es`** | es group_vars |
| `es_spi_retention_days` / `es_history_retention_days` | `7` / `14` | **`30` / `90`** (placeholders — **NO automated consumer**; retention is not enforced by this codebase, see §8.3) | es group_vars |
| `es_index_shards` | `3` | **`12`** (placeholder — confirm via worksheet; no ES-role consumer) | es group_vars |
| `arkime_es_endpoints` | single host, 3 ports | **`es-phys-01:9200 … es-phys-05:9200`** | arkime_recorders.yml |
| `arkime_pcap_retention_days` | `3` | **`7`** (confirm vs disk) | arkime_recorders.yml |
| `arkime_max_file_size_g` | `2` | **`12`** | arkime_recorders.yml |
| `capture_threads` / `packet_threads` | `1` / `1` | **`2` / `2`** (data-driven; raise per line rate) | arkime_recorders.yml |
| `max_packets_in_queue` | `10000` | **`200000`** (raise per pps) | arkime_recorders.yml |
| `capture_disable_offloads` | `false` (virtual NIC) | **`true`** (real NIC: ethtool gro/lro/tso/gso off) | arkime_recorders.yml |
| `ldap_url` | `ldap://127.0.0.1:1389` | **`ldaps://<real-AD>:636`** | arkime_recorders.yml |
| `ldap_username_attribute` / `ldap_user_filter` | `uid` / `(uid={username})` | **`sAMAccountName` / `(sAMAccountName={username})`** | arkime_recorders.yml |
| `ldap_authorization_filter` | `(uid={username})` (authorizes ANY user) | **memberOf-gating filter** (see §6.5) | arkime_recorders.yml |
| `ldap_base_dn` / `ldap_bind_dn` | `dc=lab,dc=local` / `cn=admin,...` | **real AD base / read-only svc DN** | arkime_recorders.yml |
| `ldap_ca_file` | `ca-trust.pem` | **`{{arkime_tls_path}}/ad-ca.pem`** | arkime_recorders.yml |
| `arkime_admin_ldap_group` | `arkime-admins` | **real admin group DN** | arkime_recorders.yml |
| `image_delivery_mode` | `registry` | **`load_from_archive`** | all.yml |
| Images | moving **tags** | **digest-pinned** (`@sha256:…`) | all.yml |
| `internal_ca_cn` | `FPC E2E Internal CA` | **`FPC Internal CA`** | all.yml |
| `docker_log_options` | `10m × 3` | **`20m × 5`** | all.yml |
| `dns_servers` | lab NAT DNS | **real internal DNS** (default `192.0.2.53` is a placeholder) | all.yml |
| `control_plane_cidrs` / `analyst_cidrs` | lab subnets | **real subnets** (defaults are RFC5737 placeholders) | all.yml |
| `nginx_server_name` | `fpc-e2e-rec-01` | **per-recorder FQDN** | host_vars |
| `fpc_lab` | `true` | **`false` / unset** | — |
| Lab OpenLDAP (`e2e_lab_ldap.yml`, `lab_ldap_*`) | deployed on recorder | **never run in production** | — |

### 4.2 Placeholders in production files that MUST be overridden

These are RFC5737 / `example.com` documentation placeholders shipped in `inventories/production`. Left
as-is they break the firewall, analyst access, or AD auth:

- `all.yml`: `dns_servers` (`192.0.2.53`), `control_plane_cidrs` (`192.0.2.0/24`), `analyst_cidrs` (`198.51.100.0/24`).
- `arkime_recorders.yml`: `ldap_url` (`ad.example.com`), `ldap_base_dn`, `ldap_bind_dn` (`CN=arkime-svc,…`), `arkime_admin_ldap_group` (`CN=arkime-admins,OU=Groups,DC=example,DC=com`).
- `hosts.example.yml`: all `192.0.2.x` IPs and `*.fpc.example.com` FQDNs.
- AWX: `fpc_controller_host` (`awx.example.com`), `fpc_scm_url` (`git.example.com`).

Additionally, the **AD LDAPS CA** at `ldap_ca_file` (`/fpc/arkime6/ssl/ad-ca.pem`) is **operator-staged
material with no automated stager or checker** — it is not a placeholder in a file but a PEM you must
copy to every recorder and verify before Stage 5 (§6.6).

### 4.3 Values that look reducible but must NOT change

- `arkime_user_auth_ips: 127.0.0.1/32` — Arkime 6.5.0 checks the **connecting (proxy) IP**; this trusts only the loopback Nginx proxy. It is a **security control, not a lab reduction** — do not widen.
- `es_gc_log_path` / `es_heap_dump_path` — must stay **absolute container paths** (relative breaks the JVM heap-sizing probe; see defect 8).
- `INSECURE=True` in `ldap-auth.env` — intentional (sidecar runs plain HTTP on loopback; Nginx terminates TLS). Not a misconfiguration.
- Nginx container caps `CHOWN, SETUID, SETGID, DAC_OVERRIDE, NET_BIND_SERVICE` — required (defect 13).

---

## 5. Image delivery & Execution Environment build

### 5.1 Resolve and pin image digests (out-of-band prerequisite)

No role does the `docker save`/digest-resolution step. On the build host:

```bash
docker buildx imagetools inspect docker.elastic.co/elasticsearch/elasticsearch:8.19.17
docker buildx imagetools inspect nginx:1.27-alpine
docker buildx imagetools inspect caltechads/nginx-ldap-auth-service:2.6.2
docker buildx imagetools inspect ghcr.io/arkime/arkime/arkime:v6.5.0   # verify the already-pinned digest
```

Set the resolved `sha256:` digests in `inventories/production/group_vars/all.yml`:

```yaml
es_image_digest:        "sha256:…"   # was '' CHANGEME
nginx_image_digest:     "sha256:…"   # was '' CHANGEME
ldap_auth_image_digest: "sha256:…"   # was '' CHANGEME
arkime_image_digest:    "sha256:083fc1af41bcad021eeb6b9cc630e26adae35690106d35e5193e4e8442895c66"  # verify
```

(`es_image_digest` and `arkime_image_digest` may alternatively be supplied via the AWX survey at launch.)

### 5.2 Delivery mode A — `load_from_archive` (production default)

Compose runs with **`pull: never` everywhere**, so the image must already be present on each host.

On the build host, save each digest-pinned image into the control-node/EE staging dir (`image_archive_src`
= `<repo>/images`, gitignored):

```bash
mkdir -p images
for ref in \
  ghcr.io/arkime/arkime/arkime@sha256:083fc1af41bcad021eeb6b9cc630e26adae35690106d35e5193e4e8442895c66 \
  docker.elastic.co/elasticsearch/elasticsearch:8.19.17 \
  nginx:1.27-alpine \
  caltechads/nginx-ldap-auth-service:2.6.2 ; do
    docker pull "$ref"
    name=$(echo "$ref" | tr '/:@' '___')
    docker save "$ref" | gzip > "images/${name}.tar.gz"
done
```

At run time, `docker_engine/tasks/deliver_images.yml` copies `<repo>/images/*.tar.gz` to the on-host
`image_archive_dir` (`/opt/fpc/images`) and `docker_image_load`s them.

> **🛑 EE filesystem gotcha:** the copy reads from the **EE's filesystem**, not the AWX host. The
> `*.tar.gz` are gitignored, so SCM will **not** deliver them. You must mount/inject them into the EE
> (volume mount or a pre-step) so `image_archive_src` resolves inside the EE.
>
> **🛑 Silent no-op on an empty images dir.** `deliver_images.yml` loads via
> `query('fileglob', image_archive_src ~ '/*.tar.gz')` (line 24) with **no assertion that the glob is
> non-empty**. If the tarballs are absent from the EE, the load loop iterates **zero times and reports
> OK** — the failure then surfaces much later as a `compose up pull: never` error on each host (harder to
> diagnose). There is no preflight that the four expected images are present. **Verify after staging:**
> confirm the EE/control node holds the four tarballs (count ≥ 4) before launching, and after Stage 1
> Play 1 confirm the images actually loaded on a host:
>
> ```bash
> ls -1 images/*.tar.gz | wc -l        # expect >= 4 on the control node / inside the EE
> ssh es-phys-01 'docker image ls --digests'   # expect the 4 digest-pinned images present
> ```

### 5.3 Delivery mode B — registry

```yaml
# all.yml
image_delivery_mode: registry
registry_url: "registry.internal.example.com"
registry_username: "fpc-pull"
registry_password: "{{ vault_registry_password | default('') }}"
```

`deliver_images.yml` then runs `docker_login` (only when `registry_url != ''`) and pulls each image
with `pull: not_present`.

> Registry mode also hits the AWX wiring gap (§3.3): the `FPC_REGISTRY_*` env vars are not read. Put
> registry creds in the Vault, or add the env mapping.

### 5.4 Build the Execution Environment

`awx/execution-environment.yml` is an **ansible-builder schema v3** definition (not a playbook). It
forces Python 3.12 over the awx-ee 24.6.1 (py3.9) base and excludes ovirt deps (defect 0).

```bash
python -m pip install ansible-builder        # 3.x (schema v3)
# verify awx/requirements.yml galaxy pins still match root requirements.yml first
ansible-builder build -f awx/execution-environment.yml -t fpc-ee:24.6.1 --context ./.ee-context -v3
docker tag fpc-ee:24.6.1 <registry>/fpc-ee:24.6.1
docker push <registry>/fpc-ee:24.6.1
```

EE inputs (resolved relative to `awx/`): galaxy `awx/requirements.yml`, python `awx/requirements.txt`,
system `awx/bindep.txt`. Docker Compose v2 is **intentionally absent** from the EE — it runs on the
managed hosts (installed by `docker_engine`) and is driven over SSH by `community.docker.docker_compose_v2`.

### 5.5 Register the EE in AWX

`objects.yml` does **not** create an EE object. After pushing, register `fpc-ee:24.6.1` as an Execution
Environment in the controller (with a registry pull credential), then set it on every job template and
the workflow. Easy to forget — templates otherwise run on the default/global EE.

---

## 6. AWX setup as-code

### 6.1 Apply order (load-bearing)

```bash
export CONTROLLER_PASSWORD='…'        # never commit
# 1) objects first (workflow references job templates by name)
ansible-playbook awx/job_templates/objects.yml \
  -e fpc_controller_host=https://awx.real.example.com \
  -e fpc_controller_username=<user> \
  -e fpc_scm_url=https://git.real.example.com/fpc/fpc_production_build_arikme.git
# 2) workflow after objects
ansible-playbook awx/workflow/workflow.yml \
  -e fpc_controller_host=https://awx.real.example.com \
  -e fpc_controller_username=<user>
```

### 6.2 What `objects.yml` creates

- **Organization** `FPC Platform`.
- **Project** `FPC Arkime Build` (git, branch `main`, `scm_clean`, `scm_update_on_launch: true`).
- **Inventory** `FPC Production` with two **empty static groups** `elasticsearch_physical_hosts` and `arkime_recorders`. **No inventory source** is created — host membership must be added separately.
- **Credential types** `FPC LDAP Bind`, `FPC Container Registry`.
- **Machine credential** `FPC SSH Machine` (no secret material — populate SSH user/key in the controller).
- **9 job templates** (table below). Each gets `credentials: [FPC SSH Machine, FPC Ansible Vault]`, `ask_variables_on_launch: true`, `allow_simultaneous = not cluster_mutating`.

| Job template | Playbook | `cluster_mutating` | `allow_simultaneous` |
|---|---|---|---|
| FPC Preflight | `playbooks/preflight.yml` | false | true |
| FPC Deploy Elasticsearch | `playbooks/deploy_elasticsearch.yml` | true | false |
| FPC Initialize Arkime | `playbooks/initialize_arkime.yml` | true | false |
| FPC Deploy Recorders | `playbooks/deploy_recorders.yml` | true | false |
| FPC Deploy Nginx | `playbooks/deploy_nginx.yml` | true | false |
| FPC Validate | `playbooks/validate.yml` | false | true |
| FPC Upgrade | `playbooks/upgrade.yml` | true | false |
| FPC Backup | `playbooks/backup.yml` | false | true |
| FPC Recover | `playbooks/recover.yml` | true | false |

### 6.3 Objects created out of band (NOT by objects.yml)

- The **`FPC Ansible Vault`** credential (referenced by every job template by name — must already exist or the apply fails).
- The **credential instances** of `FPC LDAP Bind` / `FPC Container Registry` (only the *types* are created).
- The **Execution Environment** object.
- **Inventory host membership** (add the 5 ES hosts + 5 recorders to their groups).

### 6.4 The workflow

`awx/workflow/workflow.yml` creates **`FPC Deploy Arkime Cluster`** (org `FPC Platform`, inventory
`FPC Production`, `allow_simultaneous: false`, `survey_enabled: true`). Linear success-only chain with
**3 manual approval gates** (each `timeout: 86400` = 24 h):

```
preflight → deploy_elasticsearch
          → 🟡 [Approve Arkime database initialization]
          → initialize_arkime → deploy_recorders → deploy_nginx → validate → backup
          → 🟡 [Approve cluster upgrade]   → upgrade
          → 🟡 [Approve disaster recovery] → recover (terminal)
```

> Edges are success-only (no failure/always branches): a failed mid-pipeline stage **halts** the
> workflow at that node. The production workflow has **no** `lab_ldap` node (that is E2E-only).

**Survey (`fpc_survey_spec`):**

| Question (variable) | Type | Choices / default | Required |
|---|---|---|---|
| `elasticsearch_nodes_per_host` | multiplechoice | `3/4/5`, default `3` | yes |
| `arkime_image_digest` | text | default `''` | no |
| `es_image_digest` | text | default `''` | no |
| `confirm_destroy` | multiplechoice | `yes/no`, default `no` | yes |

> The two image-digest fields default to empty and are not required — a careless launch can deploy
> **unpinned** images. Always populate them (or pin in `all.yml`). Survey `confirm_destroy` is consumed
> **ONLY by `recover.yml`** — it does **not** gate init (which reads `arkime_force_init`) or upgrade
> (which reads `upgrade_confirm`), neither of which is in the survey. See the subsection below.

#### 🛑 The survey does NOT satisfy the destructive-stage gates

This is the single most important operational subtlety in the workflow path. The three destructive
playbooks each assert their **own** per-stage variable, and **none of those variables is in the
survey** and **no workflow node sets them as extra_vars** (verified — `workflow.yml` passes no
`extra_data` to any node):

| Destructive stage | Playbook assert (verified) | Variable that actually gates it | In survey? | Node sets it? |
|---|---|---|---|---|
| Initialize Arkime | `arkime_force_init \| bool` (`initialize_arkime.yml:21`) | `arkime_force_init` | **no** | no |
| Upgrade | `upgrade_confirm \| default(false) \| bool` (`upgrade.yml:25,115`, **both plays**) | `upgrade_confirm` | **no** | no |
| Recover | `confirm_destroy \| bool` **and** `restore_snapshot_name \| length > 0` (`recover.yml:26,37`) | `confirm_destroy` + `restore_snapshot_name` | `confirm_destroy` only | no |

The survey's `confirm_destroy` is consumed **ONLY by `recover.yml`**. Setting survey `confirm_destroy:
yes` does **not** enable init (which reads only `arkime_force_init`) and does **not** enable upgrade
(which reads only `upgrade_confirm`). The survey question's own description text
(`"Must be yes for recover/init to proceed"`, `workflow.yml:57`) is **wrong for init** — init never
reads `confirm_destroy`.

**Net effect — fail-SAFE but misleading:** a workflow run launched with only the survey filled in will
**HALT** (not wipe) at the `initialize_arkime` node (force-init assert fails), and similarly at the
`upgrade` and `recover` nodes if reached. The workflow as shipped therefore **cannot complete the init
stage** without the operator supplying the gate var out of band.

**How to actually satisfy each gate** — the workflow has `ask_variables_on_launch: true`, so type the
per-stage var(s) into the **launch-time extra variables** field when you start the run:

```yaml
# At workflow launch (extra variables), in addition to survey answers:
arkime_force_init: true        # required to pass Stage 3 (Initialize Arkime)
# Only when intentionally driving the gated upgrade / recover stages in the same run:
upgrade_confirm: true          # required to pass Stage 8 (Upgrade)
confirm_destroy: true          # required to pass Stage 9 (Recover)
restore_snapshot_name: fpc-snapshot-<ts>   # required to pass Stage 9 (Recover)
```

These are **intentionally not in the survey** so they cannot be armed by a careless multiplechoice
default — they must be deliberately typed at the gated launch. (If you want the gated workflow to be
runnable without this out-of-band knowledge, wire `extra_data: {arkime_force_init: true}` onto the init
node, or add `arkime_force_init` to the survey — but understand that doing so weakens the deliberate-typing
safeguard.) See each destructive Stage in §7 and §10 for the matching CLI flags.

### 6.5 Production AD/LDAP values to set before deploy (`arkime_recorders.yml`)

```yaml
ldap_url: "ldaps://ad.corp.example.com:636"
ldap_base_dn: "DC=corp,DC=example,DC=com"
ldap_bind_dn: "CN=arkime-svc,OU=Service Accounts,DC=corp,DC=example,DC=com"
ldap_bind_password: "{{ vault_ldap_bind_password }}"
ldap_user_filter: "(sAMAccountName={username})"
ldap_username_attribute: "sAMAccountName"
ldap_group_attribute: "memberOf"
ldap_starttls: false                      # using LDAPS 636
ldap_ca_file: "{{ arkime_tls_path }}/ad-ca.pem"
# MUST gate on group membership AND keep {username}:
ldap_authorization_filter: "(&(sAMAccountName={username})(|(memberOf=cn=arkime-admins,{{ ldap_base_dn }})(memberOf=cn=arkime-users,{{ ldap_base_dn }})))"
arkime_user_ldap_groups: ["arkime-admins", "arkime-users"]
arkime_admin_ldap_group: "CN=arkime-admins,OU=Groups,DC=corp,DC=example,DC=com"
```

> The **role default** `ldap_authorization_filter` (`roles/nginx_ldap_proxy/defaults/main.yml:27`) is the
> unsafe `({{ldap_username_attribute}}={username})`, which authorizes **any** authenticated directory
> user. **However, production `arkime_recorders.yml` already ships a safe memberOf-gating filter**
> (`inventories/production/group_vars/arkime_recorders.yml:79`) — so the unsafe role default is **not** in
> effect for prod. Your required action is therefore **not** to author the gate from scratch, but to:
> (1) replace the EXAMPLE group CNs / base DN in the shipped filter with your real AD values, (2) keep
> the `{username}` placeholder (defect 14), and (3) ensure AD actually populates `memberOf`. The block
> above shows the values to substitute. Also stage the AD LDAPS CA at `ldap_ca_file` on each recorder
> before `deploy_nginx`, or the sidecar crash-loops (defect 17) — see §6.6 below.
>
> **`arkime_admin_ldap_group` is currently informational / not consumed at runtime.** Grep confirms it
> appears only in its own group_vars definition; no role or playbook reads it. The running auth path
> gates **membership** via the *static* `arkime_user_ldap_groups` value (rendered into
> `requiredAuthHeaderVal` in `config.ini.j2:26` and the static groups header in `default.conf.j2:88`) —
> the proxy injects a static allowed-groups value, so Arkime gates membership, not per-user identity.
> Admin role is assigned only **out-of-band** during init via `arkime_add_user.sh --admin --createOnly`
> (`init.yml:107-109`). Treat `arkime_admin_ldap_group` as a placeholder for future per-user group
> mapping; it has no runtime effect today.

### 6.6 🛑 MANDATORY MANUAL GATE — stage the AD LDAPS CA and prove the bind BEFORE Stage 5

> **No automation does any of this.** Read this section before running `deploy_nginx` (Stage 5).

The AD bind and LDAPS CA trust are **never** exercised by automation until the `caltechads` sidecar
starts during **Stage 5 (`deploy_nginx`)**. Verified gaps:

- **No AD-bind / LDAPS-CA test exists in the production path.** `preflight.yml` probes only NTP
  (`getent`) and DNS (`getent inventory_hostname`); it never probes `ldaps://<AD>:636`, never validates
  the bind DN/password, and never validates that `ldap_ca_file` chains to the AD server cert. The only
  LDAP bind/ldapsearch test in the repo is `playbooks/e2e_lab_ldap.yml` — **lab-only**, against the local
  OpenLDAP on `127.0.0.1:1389`. It is never run in production.
- **No role or playbook stages `ad-ca.pem`.** The CA at `ldap_ca_file`
  (`/fpc/arkime6/ssl/ad-ca.pem`) is **operator-staged**; grep finds it only in `ldap-auth.env.j2`
  (`LDAP_CA_CERT_NAME`) and the nginx-compose bind-mount `{{ ldap_ca_file | dirname }}:/certs:ro`. The
  bind-mount is the **dirname** (`/fpc/arkime6/ssl`, which `deploy_recorders` creates), so Compose will
  happily mount the directory with the CA file **absent** — and the sidecar then crash-loops (defect 17)
  at the very end of the pipeline.

A bad bind DN, wrong CA, or unreachable `:636` therefore surfaces as a **sidecar crash-loop at the end
of the run**, not as an early preflight failure. Close that gap manually:

**Step 1 — Stage the AD CA on every recorder** (place your AD LDAPS issuing CA PEM at `ad-ca.pem` first):

```bash
ansible -i inventories/production/hosts.yml arkime_recorders -b \
  -m copy -a 'src=ad-ca.pem dest=/fpc/arkime6/ssl/ad-ca.pem owner=root mode=0644'
```

> `/fpc/arkime6/ssl` is created by `deploy_recorders` (Stage 4); stage the CA **after Stage 4, before
> Stage 5**. (If you prefer to stage before Stage 4, create the dir first.)

**Step 2 — Verify the file is present on every recorder:**

```bash
ansible -i inventories/production/hosts.yml arkime_recorders -b \
  -m stat -a 'path=/fpc/arkime6/ssl/ad-ca.pem'
# every host must report exists: true
```

**Step 3 — Prove the LDAPS CA chain and the AD bind from a recorder** (manual; no AWX job does this):

```bash
# CA chain: the AD :636 cert must verify against ad-ca.pem
openssl s_client -connect <AD-host>:636 -CAfile /fpc/arkime6/ssl/ad-ca.pem </dev/null \
  2>/dev/null | grep -E 'Verify return code'    # expect: 0 (ok)

# Bind: the service-account DN + password must authenticate over LDAPS
LDAPTLS_CACERT=/fpc/arkime6/ssl/ad-ca.pem \
  ldapwhoami -H ldaps://<AD-host>:636 -D '<ldap_bind_dn>' -w '<bind_pw>'
# expect: dn:<the bind account> (an anonymous/failed bind is a CA, DN, or password problem)
```

> Run Step 3 from a recorder (or any host that trusts the same CA and can reach `:636`) **before
> approving / launching Stage 5**. This is a **mandatory manual gate** — there is no automated
> equivalent. It is cross-referenced from the §11 hardening checklist. (Recommended hardening follow-up:
> add a preflight assert that `ldap_ca_file` exists on every recorder whenever `ldap_url` starts with
> `ldaps://`, and an `ldapwhoami`/`s_client` smoke check — the codebase ships neither.)

---

## 7. Staged deployment via the AWX workflow

Run via the **`FPC Deploy Arkime Cluster`** workflow. The break-glass CLI equivalent for each stage is
shown. ES API probes use `elastic` / `es_bootstrap_password` over `https://{{management_ip}}:9200` with
the internal CA; all are `no_log`.

### Stage 0 — Preflight (read-only)

- **JT:** FPC Preflight · **Playbook:** `playbooks/preflight.yml` (`hosts: all_fpc_hosts`).
- Asserts (in order): OS in matrix; RAM ≥ 2048 MiB; each `es_data_devices` entry `isblk`; `(RAM−os_docker_reserve_gib)/elasticsearch_nodes_per_host ≥ es_min_container_gib`; `management_interface` present; each `capture_interfaces` present; `capture_threads ≤ host_cpu_cores`; NTP servers resolve; DNS resolves `inventory_hostname`.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/preflight.yml
```

### Stage 1 — Deploy Elasticsearch

- **JT:** FPC Deploy Elasticsearch · **Playbook:** `playbooks/deploy_elasticsearch.yml`.
- **Play 1** (all ES hosts, parallel; tags `common,docker`): `common` (sysctl `vm.max_map_count=262144`, `vm.swappiness=1`, internal CA, trust store, firewall) + `docker_engine` (install Docker CE, assert Compose ≥ 2.18.0, write `daemon.json`, deliver images).
- **Play 2** (`serial: 1`, one host at a time; tags `elasticsearch,es-health`): `elasticsearch_host` (format/mount `es_data_devices[0]`, create dirs) + `elasticsearch_cluster` (derive nodes, render config/heap/compose, ship certs, compose up `pull: never`, **health-gate** before the next host).
- Heap is computed at runtime: `usable = RAM − 13`; `limit = floor(usable / N)`; `heap = max(min(floor(limit×0.5), 26), 1)`. At N=3 on 125 GiB → ~37 GiB/container, heap ~18 GiB. The density assert fails the play if `limit < 4`.
- **Bootstrap guard:** first run emits `cluster.initial_master_nodes = <host>-node-01` for each master-eligible host; after formation `finalize_bootstrap.yml` removes it (no restart) and writes `{{es_base}}/.bootstrapped`. Restarts can never re-bootstrap.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/deploy_elasticsearch.yml
```

### Stage 2 — 🟡 APPROVAL GATE: Approve Arkime database initialization

Verify the ES cluster is **green** and `arkime_writer` auth works before approving (the gate has a 24 h
timeout). Then the workflow proceeds to Stage 3.

> **🛑 No pre-init snapshot on a greenfield first deploy.** The workflow's **Backup** stage is Stage 7
> — it runs *after* the destructive init (Stage 3), so on a first deploy there is **no snapshot to
> restore** if init goes wrong. This is acceptable on a **greenfield** cluster only because there is no
> data to lose. **On any RE-init or re-run against a cluster that already holds data, you MUST take a
> backup (`backup.yml` / FPC Backup) BEFORE approving this gate** — the only documented undo for an
> unwanted init is snapshot-restore (`recover.yml`, §10.4), which does not exist unless you made one
> first. For a re-deploy, run FPC Backup as a manual pre-step before reaching this gate.

### Stage 3 — 🔴 🟡 Initialize Arkime (GATED, one-time, destructive)

- **JT:** FPC Initialize Arkime · **Playbook:** `playbooks/initialize_arkime.yml`.
- `pre_task` refuses unless `arkime_force_init=true`. Runs `common` + `docker_engine` (db.pl runs in a container), then `arkime_recorder` `init.yml` **run_once on `arkime_recorders[0]`** against `arkime_es_endpoints[0]`: probe DB → (only if schema ABSENT) `db.pl init` → create admin via `arkime_add_user.sh --admin --createOnly` → `db.pl upgrade --ilm`.
- **🛑 AWX path — the approval gate alone does NOT arm init.** The init playbook reads **only**
  `arkime_force_init`; it never reads the survey's `confirm_destroy`. After you approve the "Approve
  Arkime database initialization" gate, the init job **still aborts** with the REFUSING-to-initialise
  assert unless `arkime_force_init: true` was supplied. Because the workflow has
  `ask_variables_on_launch: true` and passes no `extra_data` to this node, you must set
  `arkime_force_init: true` in the **launch-time extra variables** when you start the workflow (see §6.4
  → "The survey does NOT satisfy the destructive-stage gates"). Setting survey `confirm_destroy: yes`
  has **no effect** on init.
- **Double gate:** `db.pl init` fires only when DB is absent **OR** `arkime_reinit=true`. Leave `arkime_reinit` **unset** — `arkime_force_init` only *allows* init, it is **not** a force-wipe (defect 27).

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/initialize_arkime.yml -e arkime_force_init=true
```

> Verify after: `db.pl info` reports a non-negative `DB Version`, the admin user exists, ILM is installed.

### Stage 4 — Deploy Recorders (idempotent)

- **JT:** FPC Deploy Recorders · **Playbook:** `playbooks/deploy_recorders.yml` (`common`, `docker_engine`, `arkime_recorder`).
- Per recorder: create `/fpc/arkime6/{config,pcap,logs,etc,ssl}`; ship `pki/ca.crt.pem → ssl/ca-trust.pem` (https only); NIC tuning (promisc on + offloads off + `capture-nic.service` for reboot persistence); render `config.ini` + `docker-compose.yml`; bring up `fpc-arkime` (capture + viewer) `pull: never`. The role **never** runs DB init.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/deploy_recorders.yml
```

### Stage 5 — Deploy Nginx + LDAP

> **🛑 Mandatory manual pre-step (§6.6):** before launching this stage, (1) copy `ad-ca.pem` to
> `/fpc/arkime6/ssl/ad-ca.pem` on every recorder, (2) `stat` it on every host, and (3) prove the LDAPS
> CA chain (`openssl s_client … -CAfile …`) and the AD bind (`ldapwhoami -H ldaps://<AD>:636 …`). **No
> automation does this.** If the CA file is missing or the bind fails, this stage's `caltechads` sidecar
> crash-loops (defect 17) — and it is the **first** time the AD/LDAPS path is exercised in the whole
> pipeline.

- **JT:** FPC Deploy Nginx · **Playbook:** `playbooks/deploy_nginx.yml` (`common`, then `nginx_ldap_proxy`).
- Lays down `fpc-nginx` (front Nginx + `caltechads` sidecar, both `network_mode: host`). Sidecar command is exactly `nginx-ldap-auth start --host 127.0.0.1 --port 8888 --workers 1` (defects 21–23).
- **Must run AFTER recorders** — Nginx proxies the loopback viewer (`127.0.0.1:8005`).

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/deploy_nginx.yml
```

### Stage 6 — Validate (read-only)

- **JT:** FPC Validate · **Playbook:** `playbooks/validate.yml`. See §9 for the full assertion list.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/validate.yml
```

### Stage 7 — Backup (non-destructive)

- **JT:** FPC Backup · **Playbook:** `playbooks/backup.yml`. Snapshots ES into repo `fpc-fs`. See §10.1.

> **Full CLI sequence (authoritative — this per-playbook form is the single source of truth):**
> ```bash
> ansible-playbook -i inventories/production/hosts.yml playbooks/preflight.yml
> ansible-playbook -i inventories/production/hosts.yml playbooks/deploy_elasticsearch.yml
> # stage ad-ca.pem on recorders + prove the AD bind/CA (§6.6) BEFORE deploy_nginx
> ansible-playbook -i inventories/production/hosts.yml playbooks/initialize_arkime.yml -e arkime_force_init=true   # gated
> ansible-playbook -i inventories/production/hosts.yml playbooks/deploy_recorders.yml
> ansible-playbook -i inventories/production/hosts.yml playbooks/deploy_nginx.yml
> ansible-playbook -i inventories/production/hosts.yml playbooks/validate.yml
> ```
>
> **⚠ Do NOT use the README's `site.yml --tags …` form for a production build.** The README runs
> `ansible-playbook playbooks/site.yml --tags elasticsearch` and `--tags recorders,nginx` (no `-i`),
> which does **not** match the sequence above and is broken for a fresh fleet: in
> `deploy_elasticsearch.yml`, **Play 1** (`common` + `docker_engine` — installs Docker, asserts Compose
> ≥ 2.18.0, writes `daemon.json`, delivers/loads images) is tagged only **`common, docker`**, *not*
> `elasticsearch`. So `--tags elasticsearch` **skips Docker install and image delivery** on the ES hosts
> and only runs Play 2, which then fails at `compose up pull: never` with no engine/image. If you must use
> a tag-based invocation, it has to include the prep play: `--tags common,docker,elasticsearch,es-health`
> (and likewise `--tags common,docker,recorders` / include the nginx play). Prefer the per-playbook
> sequence above.
>
> `site.yml` (run with no tags) runs the non-destructive chain (preflight → ES → recorders → nginx →
> validate) but **excludes** `initialize_arkime`, `upgrade`, `backup`, `recover`.
>
> **Inventory note:** `ansible.cfg` already sets `inventory = inventories/production/hosts.yml`, so the
> explicit `-i` in every command above is for clarity only — it targets the same inventory as the
> README's `-i`-less commands. No command change is needed if you drop `-i`.

---

## 8. Sizing & the N = 3/4/5 benchmark decision

`elasticsearch_nodes_per_host` (N) is a **benchmarked decision, not a fact**. Default `3` ships; `4`/`5`
must win a benchmark before adoption. (Per the CHANGELOG, 125 GiB hosts do not reach the ~30 GiB heap
sweet spot the 256 GB predecessor used.)

### 8.1 Heap math per N (125 GiB host, `os_docker_reserve_gib=13`, `usable=112`)

| N | Containers (5 hosts) | Per-container limit | Heap (`min(floor(limit×0.5), 26)`) | Density assert (`≥4`) |
|---|---|---|---|---|
| 3 | 15 | ~37 GiB | ~18 GiB | pass |
| 4 | 20 | ~28 GiB | ~14 GiB | pass |
| 5 | 25 | ~22 GiB | ~11 GiB | pass |

All three stay under the **26 GiB compressed-oops ceiling** (`es_heap_max_gib`). Aggregate heap is nearly
flat (~270–280 GiB); density trades per-node filesystem cache for shard count.

### 8.2 How to choose (per `docs/sizing.md`)

1. Run an identical ingest + analyst-query workload at N = 3, 4, 5.
2. Record per node: sustained capture pps/**drops**, ES indexing rate, **p95 query latency**, GC pause.
3. Choose the **largest N** that keeps p95 latency and GC within target **and** zero capture drops; tie → prefer lower N.
4. Default remains N=3 until the benchmark says otherwise. Set via `elasticsearch_nodes_per_host` (group_var) or the AWX survey.

### 8.3 Capacity worksheet inputs (confirm placeholders)

`es_index_shards` (12), `es_spi_retention_days` (30), `arkime_pcap_retention_days` (7) are **placeholders**.
Confirm with measured Gbps, dup fraction, B bytes/session, S_day; target ~20–50 GB/shard; cross-check
per-node SPI disk against watermarks (low 85% / high 90% / flood 95%). `es_index_shards`/`es_index_replicas`
have **no consumer in the ES role** — they feed Arkime index init / the worksheet, not ES node config.

> **🛑 Retention is NOT enforced by this codebase.** `es_spi_retention_days` (30) and
> `es_history_retention_days` (90) **also have zero automated consumers** — grep finds them only in
> `group_vars`, referenced by no role or playbook. ILM is installed *generically* by
> `db.pl upgrade --ilm` (`init.yml:130`) with **no retention value passed**. So the documented 30/90-day
> retention is **documentation/worksheet only**: nothing the runbook deploys will expire data at those
> ages. The operator must set the actual retention manually (Arkime's ILM settings, e.g. `db.pl`/viewer
> ILM configuration, or a hand-authored ES ILM policy) and **verify it post-deploy**. Do not assume
> retention is configured because these vars are set.

---

## 9. Post-deploy validation & acceptance

`playbooks/validate.yml` (read-only, `all_fpc_hosts`) runs the `validation` role and prints a fleet
summary.

### 9.1 Elasticsearch asserts (run_once)

- `_cluster/health.status == green` **and** `number_of_nodes` == (count of `elasticsearch_physical_hosts`) × N (= **5 × N** in production). The expected count is **derived from the inventory host count** (`validation_expected_es_nodes = (groups['elasticsearch_physical_hosts'] | length) * (elasticsearch_nodes_per_host | int)`, `roles/validation/defaults/main.yml:8`), not a literal 5 — it scales with the actual ES host count.
- `unassigned_shards == 0`.
- Every node advertises `node.attr.physical_host`.
- **Master-eligible count == 3** (`validation_expected_masters` default; not gated by host count — always fires).
- **Cross-host shard-colocation** (no two copies of an index/shard on one physical host) — **gated on `(elasticsearch_physical_hosts | length) > 1`, so it ALWAYS runs in production** (5 hosts). It will FAIL if awareness is misconfigured (wrong `es_awareness_force_values` or `physical_host`).

### 9.2 Arkime asserts (recorders)

- `http://127.0.0.1:8005/` answers with `[200,401]`; `http://127.0.0.1:8005/api/stats` answers with `[200,401,403]` (per `roles/validation/tasks/arkime.yml` — the root probe accepts only 200/401; a 403 on `/` would *fail*). 401 is acceptable — viewer up and enforcing auth.
- `arkime_pcap_path` exists/`isdir` and is **writable** (probe tempfile created + removed).

### 9.3 Auth / security-boundary asserts (recorders, negative)

- Unauth `GET https://{{nginx_server_name}}:443/` → `[302,400,401,403]` (denied).
- Spoofed `remote-user` header → also `[302,400,401,403]` (forged header stripped/denied).
- `http://{{management_ip}}:8005/` → status `[-1,0]` (viewer not reachable off loopback).

### 9.4 Manual acceptance

- **AD login:** a real AD user in `arkime-admins`/`arkime-users` can sign in at `https://recNN.fpc…/` and reach the viewer.
- **Header-spoof / bypass:** confirm §9.3 (also exercised by `tests/verification/verify.yml`).
- **Emergency login:** the digest `admin` account works **from loopback only** (enforced by `userAuthIps: 127.0.0.1/32` in `config.ini.j2:28`, which restricts header-trust to loopback). **There is NO automated audit of digest logins** — the repo ships no logging/alerting task for break-glass auth (grep finds only descriptive config comments). This is a **manual operator procedure**: after any break-glass use, rotate `arkime_admin_password` (re-run the recorder role) and **manually review the Arkime viewer access logs / reverse-proxy logs** for any digest (`Authorization` header) auth. (Recommended follow-up: ship viewer/proxy logs to a central store — the platform has no audit pipeline.)
- **Fail-closed:** with AD/LDAPS unreachable, the `auth_request` subrequest does not return 200 → Nginx denies (platform fails closed).
- **Capture check:** confirm `arkime-capture` is writing pcap to `/fpc/arkime6/pcap` and sessions appear in the viewer (replay a known fixture across the SPAN/TAP).

### 9.5 Post-deploy monitoring & alerting (operator-supplied)

> **🛑 The platform ships NO metrics exporter, healthcheck endpoint, or Prometheus/alerting integration**
> (confirmed by grep — no exporter, no alert rules, no scrape config). `validate.yml` is a one-shot
> post-deploy gate, not continuous monitoring. **Operators must wire their own monitoring** against the
> signals below. Cross-reference `docs/operations.md`, which carries the full operational signals table
> and the day-2 watch list (ES `_cat/allocation` vs watermarks; disk low/high/flood at 85/90/95%).

Minimum signals to scrape/alert on after go-live (poll the ES API with `elastic` / `es_bootstrap_password`
over `https://<management_ip>:9200`, and the viewer on each recorder):

| Signal | Source | Alert threshold |
|---|---|---|
| Cluster status | `_cluster/health.status` | **!= `green`** (yellow = degraded; red = data risk) |
| Unassigned shards | `_cluster/health.unassigned_shards` | **> 0** |
| Disk watermarks | `_cat/allocation` vs `es_disk_watermark_*` | crossing **low 85% / high 90% / flood 95%** (flood → indices go read-only) |
| Capture drops | viewer `/api/stats` / ESHealth (per recorder) | **drops > 0** (capture can't keep up) |
| Viewer health | `http://127.0.0.1:8005/eshealth.json` (loopback, per recorder) | non-200 / unreachable |
| Snapshot result | last `backup.yml` snapshot state | **!= `SUCCESS`** |
| pcap free space | recorder `/fpc/arkime6/pcap` vs `arkime_free_space` (10%) | approaching the free-space floor |

See `docs/operations.md` for the authoritative signal table and the one-host-at-a-time day-2 loop.

---

## 10. Day-2 operations

> **Golden rule (`docs/operations.md`):** change **one host at a time**, validate, then move on
> (`--limit`). Routine loop: `validate.yml` (green) → disable replica allocation
> (`cluster.routing.allocation.enable: primaries`) → work one host → wait green / 0 unassigned →
> re-enable allocation → re-run `validate.yml` → next host.

### 10.1 Backups / snapshots

- **JT:** FPC Backup · **Playbook:** `playbooks/backup.yml` (`run_once` on first ES host).
- Registers repo **`fpc-fs`** (type `fs`, location `/snapshots`, compress), takes `fpc-snapshot-<timestamp>` with `wait_for_completion=true`, `include_global_state=true`, asserts `state == SUCCESS`.
- **Snapshots cover ES SPI/session metadata ONLY — NOT pcap.** Pcap is host-local, time-bounded by `arkime_pcap_retention_days` (7) and `arkime_free_space` (10%); treat as best-effort, not restorable.
- For real DR, `es_snapshot_repo_path` (`/fpc/es8/snapshots`) must be **shared/replicated storage or object store that survives host loss**, not a single host's local disk. The repo path must be present (`path.repo`) on **every** ES node.
- Repo name is **`fpc-fs`** in the playbooks (docs examples say `fpc` — the playbook value is authoritative).

### 10.2 🔴 🟡 Rolling upgrade (gated)

- **JT:** FPC Upgrade · **Playbook:** `playbooks/upgrade.yml` (both plays `serial: 1`). Data volumes are **never** touched; Compose `pull: never`.
- **Always snapshot first** (Stage 7 / §10.1). Gate: `-e upgrade_confirm=true` (asserted in **both** plays — `upgrade.yml:25` and `:115`).
- **🛑 AWX path:** the "Approve cluster upgrade" gate alone does **not** arm the upgrade. Upgrade reads
  **only** `upgrade_confirm` (not the survey's `confirm_destroy`), and no workflow node sets it. Supply
  `upgrade_confirm: true` in the **launch-time extra variables** (see §6.4); otherwise both upgrade plays
  abort with the REFUSING-to-upgrade assert.
- ES play per host: disable allocation (`enable: none`) → `_flush` → recreate ES Compose (`recreate: always`, `wait: true`) → re-enable allocation (`enable: all`) → wait green (60s timeout, 60 retries × 10s). Then the recorder play rolls each host.
- **Upgrade master-eligible hosts (es-phys-01/02/03) LAST** to keep quorum — not auto-enforced; order your `--limit`/inventory accordingly. After an ES version move, run `db.pl upgradenoprompt --ifneeded` once.

```bash
# resolve+pin new digests, bump *_version in all.yml, deliver images, take a fresh snapshot, then:
ansible-playbook -i inventories/production/hosts.yml playbooks/upgrade.yml -e upgrade_confirm=true
```

### 10.3 Scale density 3 → 4 → 5

After the benchmark justifies a higher N: set `elasticsearch_nodes_per_host` (group_var or survey),
re-deploy ES (`serial: 1`). Keep `es_master_eligible_hosts` at exactly 3, and ensure
`es_awareness_force_values` lists all 5 hosts. Re-sync the AWX inventory source after editing group_vars
(see §12).

### 10.4 🔴 🟡 Disaster recovery / destructive reset

- **JT:** FPC Recover · **Playbook:** `playbooks/recover.yml` (`run_once`). **Closes ALL indices and overwrites them** (restore-only; never deletes data volumes or the repo).
- Gates: `-e confirm_destroy=true` **and** `-e restore_snapshot_name=<snapshot>` (must exist in `fpc-fs`). With defaults, recover is a read-only no-op.
- **🛑 Global cluster state is NOT restored.** `backup.yml` takes the snapshot with
  `include_global_state: true` (line 54 — captures persistent cluster settings: awareness force values +
  disk watermarks set by `deploy_elasticsearch`), but `recover.yml` restores with
  `include_global_state: false` (line 86). So a disaster restore brings back **indices only** — it does
  **not** re-apply the persistent allocation-awareness (`es_awareness_force_values`) or disk-watermark
  settings. **After any recover, re-run `deploy_elasticsearch` (or re-PUT `_cluster/settings`) to
  re-establish those persistent settings, then run `validate.yml`** — otherwise the §9.1 shard-colocation
  assert can fail and watermarks revert to defaults.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/recover.yml \
  -e confirm_destroy=true -e restore_snapshot_name=fpc-snapshot-20260624T...
```

> **🛑 AWX path:** the "Approve disaster recovery" gate alone does **not** arm recover. `recover.yml`
> asserts **both** `confirm_destroy` (survey-supplied is fine here, since recover is the one playbook that
> reads it) **and** `restore_snapshot_name` (which is **not** in the survey and on no node). Supply
> `confirm_destroy: true` **and** `restore_snapshot_name: <snap>` in the **launch-time extra variables**;
> otherwise the recover job aborts on the missing-snapshot-name assert (`recover.yml:37`).

- **Re-init the Arkime DB** (rare, destructive): `initialize_arkime.yml -e arkime_force_init=true -e arkime_reinit=true` — **wipes** all sessions/metadata. Never set `arkime_reinit` in normal operation.

### 10.5 Replace a failed host (no full restore)

- **Failed ES host:** re-image OS, restore inventory identity (`management_ip`, `physical_host`), run `site.yml --limit <host>`. The bootstrap guard makes it **rejoin** (never re-bootstrap). Wait green / 0 unassigned, then `validate.yml`. **Do NOT** use `recover.yml`. (Under `--limit <es-host>`, `site.yml`'s recorder/nginx plays no-op — no matching hosts — and the validate play's `run_once` cluster asserts still evaluate the **whole** cluster; that is expected. Wait for green / 0 unassigned before relying on the validate result.)
- **Failed recorder:** re-image, restore `management_interface`/`capture_interfaces`/`nginx_server_name`, run `site.yml --limit <recorder>`.
- No automation deletes data: ES data path, snapshot repo path, and pcap path always persist across Compose recreate.

---

## 11. Production hardening & security checklist

- [ ] `es_http_tls: true`, `es_transport_tls: true`, `es_security_enabled: true`; `arkime_es_scheme: https`.
- [ ] `vault_internal_ca_key_passphrase` set (CA key encrypted, not the default empty/unencrypted).
- [ ] All `vault_*` provided via encrypted Vault (group-matching path) **or** AWX Vault credential; LDAP bind + registry creds in the **Vault** (env-injecting types are not wired).
- [ ] `vault_es_arkime_writer_password` non-empty (else `es_security.yml` skipped → recorders 401).
- [ ] Arkime `passwordSecret`/`serverSecret` via `openssl rand -hex 32`, **identical** across all 5 recorders.
- [ ] All four images digest-pinned (`@sha256:`), not tags; tarballs present in the EE (archive mode); image-load is **non-empty** (the load loop silently no-ops on an empty dir — verify `docker image ls` on a host after Stage 1, §5.2).
- [ ] `ldap_authorization_filter` gates on `memberOf` of real groups. **Prod already ships a safe memberOf filter** (`arkime_recorders.yml:79`) — replace the EXAMPLE group CNs / base DN with real AD values (do not revert to the unsafe role default); ensure AD populates `memberOf`.
- [ ] **AD bind & LDAPS CA proven manually BEFORE Stage 5 (§6.6):** `ad-ca.pem` staged + `stat`'d on every recorder; `openssl s_client` verifies the `:636` cert against it (return code 0); `ldapwhoami -H ldaps://<AD>:636 -D '<bind_dn>'` succeeds. No automation does this; a miss = sidecar crash-loop (defect 17).
- [ ] **Destructive-stage extra vars understood (§6.4):** the survey's `confirm_destroy` does NOT arm init/upgrade; supply `arkime_force_init: true` (init), `upgrade_confirm: true` (upgrade), `confirm_destroy: true` + `restore_snapshot_name` (recover) as launch-time extra vars.
- [ ] **Pre-init backup taken** on any re-deploy / re-init against a cluster with data (no pre-init snapshot exists on the workflow's success-chain — Backup is Stage 7; see §7 Stage 2).
- [ ] **ILM retention configured manually** — `es_spi_retention_days`/`es_history_retention_days` have NO automated consumer; set and verify the actual Arkime/ES ILM policy post-deploy (§8.3).
- [ ] **Digest-login audit is manual** — no automated audit pipeline exists; review viewer/proxy logs for `Authorization`-header auth and rotate `arkime_admin_password` after break-glass use (§9.4).
- [ ] **Monitoring wired by the operator** — platform ships no exporter/alerting; alert on cluster status != green, unassigned shards > 0, watermark crossings, capture drops > 0, snapshot != SUCCESS (§9.5, `docs/operations.md`).
- [ ] **Recover re-applies global cluster state** — after `recover.yml` (restores `include_global_state:false`), re-run `deploy_elasticsearch` (or re-PUT `_cluster/settings`) then `validate.yml` (§10.4).
- [ ] **Inter-tier reachability confirmed manually** — preflight does NOT check SSH/ES/Nginx/registry ports (§1 preflight scope caveat / §7 Stage 0).
- [ ] `arkime_user_auth_ips: 127.0.0.1/32`; viewer bound to `127.0.0.1:8005`; never widened/exposed.
- [ ] Nginx header stripping intact (`X-Remote-User`, `X-Forwarded-User`, `X-Authenticated-User`, `Authorization` blanked, identity set only from the subrequest).
- [ ] Nginx caps `CHOWN, SETUID, SETGID, DAC_OVERRIDE, NET_BIND_SERVICE` kept; capture caps `NET_RAW, NET_ADMIN` only.
- [ ] `firewall_enabled: true`; `firewall_manager` matches OS (`ufw` Ubuntu / `firewalld` Rocky); `control_plane_cidrs`/`analyst_cidrs` real.
- [ ] **Rocky note:** the `firewalld` path does **not** add the port-80 redirect rule the `ufw` path does — add it manually if `nginx_redirect_http` on Rocky recorders (defect 18).
- [ ] Public Nginx cert is enterprise-CA-signed (or distribute the FPC Internal CA to analyst browsers).
- [ ] `pki/` (CA key + node keys) protected and backed up; `host_key_checking=True` SSH host keys accepted.
- [ ] `confirm_destroy: no`, `arkime_force_init: false`, `arkime_reinit` unset in normal operation.
- [ ] `air_gapped` set correctly (true only for a real air-gap; relaxes ES TLS verify).
- [ ] `fpc_lab` false/unset; `e2e_lab_ldap.yml` never run; lab `bitnamilegacy/openldap` absent.
- [ ] Sensitive renders confirmed: `config.ini` 0640, `ldap-auth.env` 0600, ES `node.key.pem` 0640 `1000:1000`, Nginx `key.pem` 0640.

---

## 12. Troubleshooting (grounded in the 28 E2E defects)

The defects below were found and fixed during E2E (`artifacts/e2e/defect-log.md`). Most are repository
defects already fixed in the shipped roles; the entries flag production-relevant residue and operator
pitfalls.

| # | Symptom | Cause / fix | Production relevance |
|---|---|---|---|
| 0 | `ansible-builder` fails: ansible-core 2.21.1 unavailable on py3.9; ovirt wheels fail | EE forces python3.12 + `package_manager_path /usr/bin/dnf` + excludes ovirt | Rebuild a custom EE; do not reuse stock `awx-ee` |
| 1 | `apt install chrony` 404 (stale cache) | `common` now `apt update` (cache_valid_time 3600) before install | Fixed |
| 2 | `python3-debian is not installed` | `install_debian.yml` installs `python3-debian` for `deb822_repository` | Fixed |
| 3 | dockerd: `invalid character '#'` in daemon.json | template emits pure JSON | Fixed |
| 4 | ES API hardcoded https when `es_http_tls=false` | scheme/`validate_certs`/`ca_path` honor `es_http_tls` | **Prod uses https.** Ensure CA **consistency across AWX jobs** — the internal CA is generated on the ephemeral EE pod per job, so each job's CA can differ; persist/ship the CA before enabling https at multi-host scale |
| 5 | init ran before recorder had Docker/image | `initialize_arkime.yml` runs `common`+`docker_engine` first | Fixed |
| 6 | `docker_image_pull` invalid `source` | uses `pull: not_present` | Fixed |
| 7 | "Wrong or empty passphrase" on CA key | empty passphrase conditionally omitted | If you set `vault_internal_ca_key_passphrase`, it is reused for ES + Nginx ownca signing |
| 8 | ES crash-loop: `Error opening log file 'logs/gc.log'` | GC log/dump paths must be **absolute** | **Affects production** — keep `es_gc_log_path`/`es_heap_dump_path` absolute |
| — | group_vars edits never reach AWX | AWX caches group_vars at last sync | **Re-sync the AWX inventory source (not just the project) after any group_vars edit**, or jobs run stale |
| 9 | db.pl CA mount on http; `db.pl upgrade` prompts on closed stdin | CA gated on https; `UPGRADE` piped | Fixed |
| 10 | `--esuser arkime_writer:` (empty) → ES 401 | writer password sourced from `vault_es_arkime_writer_password` first | **Set `vault_es_arkime_writer_password` fleet-wide** or db.pl/capture/viewer get 401 |
| 11 | init temp config.ini in non-existent dir | init ensures `arkime_config_path` first | Fixed |
| 12 | viewer crash `EISDIR` on caTrustFile | caTrustFile/CA mount/ship gated on https | Fixed; prod is https so CA must be valid |
| 13 | nginx `chown … Operation not permitted` crash-loop | restored caps CHOWN/SETUID/SETGID/DAC_OVERRIDE | Do not regress nginx caps |
| 14 | `ldap_authorization_filter does not use {username}` | filter requires `{username}`; user filter uses `{username}` | Keep `{username}` in your prod filter |
| 15 | validate: `dict has no attribute 'node'` | master count from `_nodes` roles list | Fixed |
| 16 | shard-colocation "two copies on one host" (single-host lab) | gated on `>1` ES host | **In prod (5 hosts) this check RUNS** — a real failure means awareness is misconfigured |
| 17 | sidecar crash: `ldap_ca_cert_name does not exist` | CA env only for ldaps/StartTLS | **Stage the AD CA at `ldap_ca_file` before deploy_nginx** |
| 18 | `http://recorder/ → 000` | allow tcp/80 from `analyst_cidrs` when `nginx_redirect_http` | **firewalld (Rocky) does not add this rule — add manually** |
| 19 | validate: undefined `nginx_version`/`arkime_viewer_port` | summary uses `nginx_image`/`ldap_auth_image`; default added | Fixed |
| 20 | validate auth: `CERTIFICATE_VERIFY_FAILED` | auth status probes use `validate_certs: false` | TLS validity verified separately |
| 21/22 | sidecar bound container hostname (127.0.2.1) | command `--host 127.0.0.1` | Do not change the sidecar command |
| 23 | intermittent 401 with multiple workers | `--workers 1` (in-memory sessions) | Do not raise `--workers` |
| 24 | login cookie not validated | `/auth` + `/check-auth` send `X-Cookie-Name` + `X-Cookie-Domain` | Keep both headers identical |
| 25 | lab bind DN mismatch | lab-only (`uid=…`) | Lab only |
| 26 | authenticated check hit `/` (302) | check `/api/user` (200) | Test-artifact |
| 27 | `arkime_force_init=true` re-wiped DB every run | init runs only when schema absent OR `arkime_reinit=true` | **`arkime_force_init` allows init; it is NOT a force-wipe.** Never set `arkime_reinit` unless intentionally wiping |
| 28 | lab OpenLDAP seed raced slapd | retry seed (lab only) | Lab only |

### 12.1 Quick diagnostics

```bash
# ES container density / heap actually loaded
ssh es-phys-01 'docker compose -p fpc-es ls; docker image ls --digests'
# Cluster health (from a node)
curl -s --cacert /fpc/es8/config/es-phys-01-node-01/certs/ca.crt.pem \
  -u elastic:"$ES_PW" https://<management_ip>:9200/_cluster/health?pretty
# Compose plugin version (role asserts >= 2.18.0)
ssh es-phys-01 'docker compose version --short'
# Viewer health on a recorder (loopback only)
ssh arkime-rec-01 'curl -fsS http://127.0.0.1:8005/eshealth.json'
# Confirm daemon.json (20m x 5 local driver)
ssh es-phys-01 'cat /etc/docker/daemon.json'
```

---

## 13. Rollback boundaries per stage

| Stage | Mutates | Rollback boundary |
|---|---|---|
| Preflight | nothing | None needed — read-only asserts. |
| Docker prep (Play 1) | installs Docker, writes `daemon.json` (restarts dockerd; `live-restore: true`), loads images | Idempotent; re-run safe. A daemon restart occurs mid-role — sequence carefully (Play 1 runs across all ES hosts together). |
| Deploy ES (Play 2, `serial:1`) | creates FS/mounts on `es_data_devices`, brings up `fpc-es` | **Never wipes data volumes.** A stuck health gate (up to ~10 min/host) halts the rollout at that host. **Do NOT delete `{{es_base}}/.bootstrapped`** — that risks re-bootstrap/split-brain. Roll back by fixing config and re-running (compose recreate, `pull: never`). |
| 🟡 Approve init | nothing | Decline the approval to abort before any Arkime mutation. |
| 🔴 Initialize Arkime | `db.pl init` (drops/recreates indices) only if schema absent, admin create, ILM | If schema already present, re-runs are idempotent (no wipe). There is no in-place undo of `init`. Recovery from an unwanted wipe = restore from snapshot (`recover.yml`) — **but on a greenfield first deploy NO pre-init snapshot exists** (Backup is Stage 7, after init), so there is nothing to restore. Acceptable on greenfield (no data to lose); on any re-init against a cluster with data, **take a backup BEFORE approving init** (§7 Stage 2). |
| Deploy Recorders | dirs, NIC tuning, `fpc-arkime` up | Idempotent; safe to re-run. Pcap volume persists. Config/image change triggers compose restart. |
| Deploy Nginx | `fpc-nginx` up | Idempotent; safe to re-run. Must run after recorders (dead upstream otherwise). |
| Validate | nothing | Read-only; failure means a prior stage needs remediation (no rollback). |
| Backup | writes snapshot to `fpc-fs` | Non-destructive; additive snapshots. |
| 🔴 🟡 Upgrade | recreates Compose (`pull:never`), per host | **Data volumes untouched.** Snapshot before. If a host fails to go green, allocation re-enable + green wait halts the roll; fix and re-run with `-e upgrade_confirm=true`. Roll back by deploying the prior pinned digests. |
| 🔴 🟡 Recover | closes ALL indices, restores snapshot | **Restore-only; never deletes volumes/repo.** Interrupts capture/search during restore. The boundary is the chosen `restore_snapshot_name`; there is no "undo" beyond restoring a different snapshot. **Restores indices only (`include_global_state: false`)** — persistent cluster settings (awareness force values, disk watermarks) are NOT restored; re-run `deploy_elasticsearch` (or re-PUT `_cluster/settings`) then `validate.yml` after any recover. |

---

## Appendix A — On-disk layout

| Path | Purpose |
|---|---|
| `/fpc` | `fpc_base` |
| `/fpc/es8` | `es_base` (data/logs/config/snapshots derive from this) |
| `/fpc/es8/.bootstrapped` | ES bootstrap marker (per host; never delete) |
| `/fpc/es8/snapshots` | `es_snapshot_repo_path` → `/snapshots` in containers |
| `/fpc/arkime6` | `arkime_base` |
| `/fpc/arkime6/{config,pcap,logs,etc,ssl}` | Arkime config / pcap / logs / etc / TLS |
| `/fpc/arkime6/config/nginx` | `nginx_compose_dir` (`fpc-nginx` project) |
| `/fpc/arkime6/ssl/ca-trust.pem` | internal CA shipped to recorders (https) |
| `/fpc/arkime6/ssl/ad-ca.pem` | **operator-staged** AD LDAPS CA (`ldap_ca_file`) |
| `/fpc/arkime6/ssl/{cert.pem,key.pem}` | Nginx public cert/key (enterprise or internal) |
| `/fpc/pki` | `internal_ca_dir` on hosts |
| `<repo>/pki` | control-node CA + per-node private keys (gitignored, 0700) |
| `<repo>/images` | `image_archive_src` (gitignored `*.tar.gz`) |
| `/opt/fpc/images` | `image_archive_dir` (on-host staged tarballs) |

## Appendix B — Compose projects & ports

| Project | Services | Host ports |
|---|---|---|
| `fpc-es` | N × ES nodes (host networking) | HTTP `9200..9200+N-1`, transport `9300..9300+N-1` |
| `fpc-arkime` | `arkime-capture`, `arkime-viewer` | viewer `127.0.0.1:8005` (loopback) |
| `fpc-nginx` | `fpc-nginx`, `fpc-ldap-auth` | Nginx `443` (+ `80` redirect); sidecar `127.0.0.1:8888` |

Firewall matrix: SSH 22 ← `control_plane_cidrs` (all); ES transport 9300..9300+N-1 ← ES peers (ES hosts);
ES HTTP 9200..9200+N-1 ← recorder peers + `control_plane_cidrs` (ES hosts); Nginx 443 (+80 ufw) ←
`analyst_cidrs` (recorders).
