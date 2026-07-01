# Disaster recovery

Principles: **never delete data volumes**, re-image and **rejoin** (never
re-bootstrap), and keep destructive flows behind explicit guards
(`confirm_destroy`, `arkime_force_init`).

## Snapshot and restore (Elasticsearch SPI)

Snapshots are the durable backstop and the only supported ES rollback path.

* **Repository.** A shared snapshot repo at `es_snapshot_repo_path`
  (`/fpc/es8/snapshots`) reachable by all data nodes. For real DR use repo
  storage that survives a host loss (shared/replicated mount or object store),
  not a single host's local disk.
* **Take a snapshot** (also done automatically before upgrades):

  ```json
  PUT /_snapshot/fpc/snap-{now/d}?wait_for_completion=false
  { "indices": "*", "include_global_state": true }
  ```

* **Restore** (target cluster must be same or newer ES version):

  ```json
  POST /_snapshot/fpc/<snapshot>/_restore
  { "indices": "*", "include_global_state": false }
  ```

* **What snapshots do and do not cover.** They protect **SPI/session metadata in
  ES**. They do **not** back up **PCAP** — PCAP lives on each recorder's local
  disk and is governed by retention; treat raw PCAP as best-effort, time-bounded
  data, not a restorable asset.

## Replace a failed Elasticsearch host

A lost host = a lost failure domain. Because replicas live on other hosts, there
is **no data loss** for `es_index_replicas ≥ 1`; the cluster stays yellow and,
after `node_left.delayed_timeout`, rebuilds missing replicas elsewhere.

1. **Re-image** the host with the base OS; restore its identity
   (`management_ip`, `physical_host`) in inventory/host_vars.
2. **Re-run the deploy scoped to that host:**

   ```bash
   ansible-playbook -i inventories/production/hosts.yml playbooks/site.yml \
     --limit <failed-host>
   ```

3. The host **rejoins** the existing cluster. The **bootstrap guard** ensures it
   does **not** re-bootstrap: `cluster.initial_master_nodes` is rendered only
   when `es_bootstrap_marker` is absent, and finalize removes it after the first
   formation. A re-imaged host that lost its data simply gets shards re-allocated
   to it; one that kept its data device rejoins with its shards intact.
4. Wait for **green / 0 unassigned**, then run `validate.yml`.

> If the failed host was master-eligible, the remaining 2 masters held quorum
> throughout. Restore the third master host the same way — never spin up a brand
> new cluster to "recover".

## Replace a failed recorder

Re-image, restore inventory identity (interfaces, `nginx_server_name`), run
`site.yml --limit <recorder>`. It re-registers as an Arkime node and resumes
capture. PCAP captured before the failure is gone unless the data disk survived;
SPI already in ES is unaffected.

## The guarded `recover.yml`

`playbooks/recover.yml` performs the **destructive** recovery steps that the
normal site run deliberately refuses to do (e.g. re-initialising the Arkime DB,
forcing a re-bootstrap of a cluster believed lost). It is gated:

* It runs its destructive tasks **only when `confirm_destroy: true`** (and, for
  Arkime DB re-init, `arkime_force_init: true`) is passed explicitly:

  ```bash
  ansible-playbook -i inventories/production/hosts.yml playbooks/recover.yml \
    -e confirm_destroy=true --limit <host>
  ```

* With the guards at their defaults (`false`), `recover.yml` is a **no-op /
  read-only assessment** — it asserts the guard and skips anything destructive.
* It honors `--limit` so recovery is always scoped to the affected host(s).

## No-volume-deletion policy

* Roles and playbooks **never delete ES data, snapshot, or PCAP volumes/dirs.**
  Compose projects are recreated (`Recreate ...` / `Restart ...` handlers) but
  data paths (`es_data_path`, `es_snapshot_repo_path`, `arkime_pcap_path`)
  persist.
* Recovery is **always re-image + rejoin**, never "wipe and rebuild". Removing
  data is a manual, deliberate, out-of-band action — there is no automation that
  does it for you, by design.
