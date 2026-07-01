# End-to-end smoke test (AWX-driven, VMware Vagrant)

This describes the **isolated** two-VM end-to-end (E2E) test that deploys the
full FPC stack through the already-running AWX instance, using the **same
production roles/playbooks** with a lab inventory. It does not touch the
production inventory, and it only ever creates/destroys `fpc-e2e-*` VMs and
`FPC-E2E *` AWX objects.

## Topology

| VM | Role | Containers |
|----|------|-----------|
| `fpc-e2e-es-01` | Elasticsearch physical host | 3 ES nodes (single-host lab cluster) |
| `fpc-e2e-rec-01` | Arkime recorder | capture + viewer + nginx + ldap-auth + lab OpenLDAP |

Both VMs get a NAT interface (AWX reaches them over the shared vmnet8 NAT
192.168.184.0/24) and a host-only interface for the inter-node lab network.

## Lab reductions (vs production)

These are inventory values only — **no role/playbook logic is forked**:

- One ES physical host (3 nodes) instead of five; `es_index_replicas: 0`;
  `validation_expected_masters: 1`; the cross-host shard-awareness assertion is
  skipped (only meaningful with ≥2 hosts).
- ES HTTP TLS is **off** in the lab (`es_http_tls: false`) to avoid shipping an
  ephemeral CA across AWX jobs; transport TLS and native-realm auth stay on.
- Small JVM heaps (`es_heap_max_gib: 1`).
- A throwaway OpenLDAP container (`bitnamilegacy/openldap`) provides the
  directory; a clean login user `uid=analyst,dc=lab,dc=local` is seeded via
  `ldapadd`. Group→role auto-mapping is not exercised (no memberOf overlay).
- All secrets are lab throwaways kept in the gitignored `.e2e-state/`.

## Prerequisites

- The AWX instance running at `http://127.0.0.1:30080/` (left untouched).
- `vagrant` + `vagrant-vmware-desktop`, `git` (for the SCM daemon), Python venv
  at `.lintvenv` with `requests`.
- A populated `.e2e-state/` (0700) holding the SSH keypair, vault password,
  `secrets.env`, AWX token, discovered `vm_ips.env`. These are generated during
  setup and never committed.

## One-time setup

1. **Bring up the VMs**

   ```bash
   ( cd vagrant/e2e_smoke && VAGRANT_DEFAULT_PROVIDER=vmware_desktop vagrant up )
   bash tests/e2e/discover_ips.sh        # writes inventories/e2e/host_vars + .e2e-state/vm_ips.env
   ```

2. **Build & import the custom Execution Environment** (ansible-core 2.21 + the
   pinned collections) and load it into the AWX K3s containerd:

   ```bash
   bash tests/e2e/import_ee_to_k3s.sh
   ```

3. **Serve the repo over git and create the FPC-E2E AWX objects**
   (organization, project, custom credential type + credential, inventory +
   SCM inventory source, EE, the 7 job templates, and the workflow):

   ```bash
   python tests/e2e/awx_provision.py
   ```

## Running the deployment

```bash
python tests/e2e/resync.py                         # sync AWX project + inventory to the latest commit
python tests/e2e/awx_launch.py wf "FPC-E2E Workflow"   # run the full workflow, auto-approving the gate
```

The workflow stages: `preflight → deploy_elasticsearch → [approval] →
initialize_arkime → deploy_recorders → lab_ldap → deploy_nginx → validate`.

> **Important process note:** after editing the repo you must run
> `tests/e2e/resync.py`, which updates **both** the AWX project **and** the SCM
> inventory source. Updating only the project leaves group_vars stale.

## Verifying

```bash
bash tests/e2e/verify.sh             # ES + Arkime + proxy security boundaries (17 checks)
bash tests/e2e/arkime_ingest_check.sh # offline PCAP import -> searchable -> PCAP retrieval (4 checks)
bash tests/e2e/auth_login_check.sh   # LDAP login / invalid / emergency digest / LDAP-outage (5 checks)
```

## Idempotence, restart & clean rebuild

- **Idempotence:** re-run the workflow unchanged; the destructive `db.pl init`
  is skipped once the schema exists (`arkime_reinit=true` is required for a
  deliberate reset).
- **Restart recovery:** `vagrant reload`; containers come back under their
  restart policy and the cluster never re-bootstraps (the `.bootstrapped` guard).
- **Clean rebuild (full reproducibility):**

  ```bash
  bash tests/e2e/rebuild.sh    # destroys ONLY the E2E VMs, recreates, re-syncs, redeploys, re-verifies
  ```

## Teardown

```bash
( cd vagrant/e2e_smoke && VAGRANT_DEFAULT_PROVIDER=vmware_desktop vagrant destroy -f )
```

The FPC-E2E AWX objects can be left in place for the next run; they are all
prefixed `FPC-E2E` and isolated from production.
