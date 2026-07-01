# FPC Arkime — End-to-End Deployment Test Report (sanitized)

**Test type:** real end-to-end deployment of the full FPC stack onto **freshly
created** VMware Vagrant VMs, driven entirely through the existing **AWX**
instance, using the **production roles/playbooks** with a lab inventory.
**Tested commit:** `5870a56` · **Result: PASS** (all acceptance criteria met).

No production inventory, credentials, hostnames, or IPs were used or modified.
Only `fpc-e2e-*` VMs and `FPC-E2E *` AWX objects were created. AWX itself was
left running and untouched.

## 1. Topology

| VM | Role | Containers |
|----|------|-----------|
| `fpc-e2e-es-01` | Elasticsearch physical host | 3 ES nodes (single-host lab cluster) |
| `fpc-e2e-rec-01` | Arkime recorder | capture + viewer + nginx + ldap-auth + lab OpenLDAP |

Custom Execution Environment built for the run: `fpc-e2e-ee:1.0`
(manifest `sha256:510d5fe6…`), imported into the AWX K3s containerd.

## 2. AWX workflow

`preflight → deploy_elasticsearch → [approval gate] → initialize_arkime →
deploy_recorders → lab_ldap → deploy_nginx → validate`

Representative **fully green** workflow jobs: **195** (first end-to-end green),
**207** (with the complete Nginx↔LDAP auth flow), **219 / 231** (idempotence),
**253** (clean rebuild from scratch). Every stage finished with `failures=0`.

## 3. Verification results

### 3.1 Elasticsearch + Arkime + proxy security — `verify.sh` → 17/17 PASS
- ES: exactly 3 node containers; cluster **green**; `number_of_nodes==3`;
  anonymous API **denied (401)**; `arkime_writer` authenticates; bootstrap
  marker present; **no `initial_master_nodes`** after bootstrap; `Xms==Xmx`.
- Arkime: capture + viewer running; capture has `NET_RAW` (not fully
  privileged); `arkime_*` indices present; viewer answers only on loopback.
- Security: unauthenticated request **denied**; HTTP→HTTPS **301**; spoofed
  `remote-user` header **rejected**; direct viewer bypass **blocked**.

### 3.2 Packet ingestion — `arkime_ingest_check.sh` → 4/4 PASS
- Deterministic fixture PCAP imported offline; sessions **searchable in ES**
  (dst `10.99.0.80`); session metadata carries source `10.99.0.10`; DNS host
  `fpc-e2e-smoke.example.test` searchable; **PCAP retrieval** via the viewer
  API returns the packet bytes.

### 3.3 Authentication — `auth_login_check.sh` → 5/5 PASS
- Valid LDAP login (`analyst`) reaches the viewer (**200**).
- Invalid login **denied**.
- Local emergency **digest admin** authenticates at the viewer.
- Wrong emergency password **rejected (401)**.
- **LDAP outage fails closed** (login denied while the directory is down).

## 4. Resilience / lifecycle

| Test | Result |
|------|--------|
| **Idempotence** (re-run workflow unchanged) | PASS — green; destructive `db.pl init` **skipped**; ingested data survived |
| **Reboot** (`vagrant reload` both VMs) | PASS — cluster green, data persisted, **no re-bootstrap** (`.bootstrapped` guard) |
| **Container recreate** (remove one ES node) | PASS — recovery path restored the node; cluster green, no re-bootstrap |
| **Clean rebuild** (destroy + recreate from scratch) | PASS — full AWX deploy green; 26/26 verification checks |

## 5. Static validation

`yamllint`: PASS · `ansible-lint --profile production`: **PASS (0 failures)** ·
no secrets tracked (gitignored `.e2e-state/` 0700 + `artifacts/`; vault file is
ansible-vault encrypted).

## 6. Defects found and fixed (28)

A real deployment found real bugs in the freshly-generated repo; all are fixed
and committed. Highlights (full log in `artifacts/e2e/defect-log.md`):

| # | Area | Defect |
|---|------|--------|
| 0 | EE build | ansible-core 2.21 uninstallable on the awx-ee py3.9 base; ovirt wheels failed → py3.12 interpreter, dnf, exclude ovirt |
| 1–2 | common/docker | stale apt cache (chrony 404); `deb822_repository` needs `python3-debian` |
| 3 | docker | `daemon.json` had a `#` comment → invalid JSON → dockerd refused |
| 6 | docker | `docker_image_pull` used an invalid `source` param |
| 8 | ES | relative JVM GC log path crash-looped the JVM probe → absolute paths |
| 10 | recorder | empty ES writer password → `arkime_writer:` → 401; sourced from vault |
| 12 | recorder | viewer EISDIR on a stray `caTrustFile` dir over HTTP ES → gate CA on https |
| 13 | nginx | container crashed (`chown` not permitted under `cap_drop: ALL`) → add caps |
| 15–16 | validation | dotted `_cat` key broke `selectattr`; single-host shard-colocation check |
| 17 | ldap-auth | CA-cert env set for plain `ldap://` → pydantic crash-loop |
| 18 | firewall | port 80 blocked → HTTPS redirect unreachable |
| 21–24 | nginx↔ldap | sidecar bound container hostname; 2 workers vs in-memory sessions; missing `X-Cookie-Name`/`X-Cookie-Domain` on login + check |
| 25 | lab LDAP | sidecar constructs `uid=<u>,<base>`; seeded a matching clean login user |
| 27 | recorder | `initialize_arkime` re-wiped the DB every forced run → now only inits when absent (idempotence/data-safety) |
| 28 | lab LDAP | user seed raced freshly-started OpenLDAP → retry until ready |

## 7. Known limitations (lab reductions, documented)

- **Single ES physical host**: the cross-host shard-awareness assertion is
  skipped (meaningful only with ≥2 failure domains). The 2-VM topology validates
  behavior/topology, not multi-host shard separation.
- **ES HTTP TLS disabled in the lab** to avoid shipping an ephemeral CA between
  AWX jobs; **transport TLS and native-realm auth remain enabled**.
- **LDAP group→role auto-mapping not exercised** (lab OpenLDAP has no `memberOf`
  overlay); the lab authorizes any authenticated directory user. Production gates
  on group membership via `ldap_authorization_filter`.

## 8. Reproduce

See `docs/e2e-testing.md`. One command for the from-scratch proof:
`bash tests/e2e/rebuild.sh`.
