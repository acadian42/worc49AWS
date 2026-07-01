# Operations

Day-2 runbook. Golden rule: **change one host at a time**, validate, then move
on. Re-run the relevant role with `--limit`; never hand-edit containers.

## Health and observability

Scrape / watch these regularly:

| Source                         | Signal                                   | Watch for                              |
|--------------------------------|------------------------------------------|----------------------------------------|
| ES `_cluster/health`           | status, `unassigned_shards`, `number_of_nodes` | status != green, unassigned > 0  |
| ES `_cat/nodes`                | node count, roles, heap %, load          | missing node, heap > 75% sustained     |
| ES `_nodes/stats` (JVM/GC)     | GC pause time, old-gen occupancy         | long/old-gen GC pauses                 |
| ES `_cat/allocation`           | disk used per node vs watermarks         | crossing low/high/flood                |
| ES `_cat/thread_pool/write,search` | queue + rejected                     | rejections (under-provisioned)         |
| Arkime viewer `/api/stats` & ESHealth | dropped packets, capture pps      | drops > 0 (capture can't keep up)      |
| Arkime capture logs            | disk free vs `arkime_free_space`         | approaching free-space floor           |
| Nginx access/error logs        | 401/403 rate, upstream errors            | auth failures spike, viewer 5xx        |

The reusable `validation` role (run via `tests/verification/verify.yml` or
`playbooks/validate.yml`) asserts green cluster, expected node/master counts,
awareness attributes, and the auth boundary — run it after every change.

## ES CLI administration

The cluster runs with TLS + native-realm auth on, but ad-hoc `curl` stays
flag-free: the `common` role installs the internal CA into **every host's OS
trust store** (`/usr/local/share/ca-certificates/fpc-internal-ca.crt` on Debian,
`/etc/pki/ca-trust/source/anchors/` on RHEL), so curl trusts the ES HTTP cert
automatically — **no `--cacert`** — whenever you run from an FPC host. Run admin
commands from an ES node (or any FPC host).

Admin requires the `elastic` superuser (password = `vault_es_bootstrap_password`);
`arkime_writer` is least-privilege and cannot change cluster settings.

**One-time setup — drop the `-u` flag too** with a `~/.netrc` (curl reads it
automatically with `-n`):

```bash
# ~/.netrc   (chmod 600)  — one line per ES host FQDN you target
machine es-phys-01 login elastic password <ES_ELASTIC_PASSWORD>
machine es-phys-02 login elastic password <ES_ELASTIC_PASSWORD>
# ...es-phys-03..05
chmod 600 ~/.netrc
```

**Helper** (add to `~/.bashrc` on an ES host):

```bash
ES_HOST=${ES_HOST:-es-phys-01}                 # override per call: ES_HOST=es-phys-03 esadmin ...
esadmin() {                                     # usage: esadmin <METHOD> <path> [curl args...]
  local method=$1 path=$2; shift 2
  curl -sS -n -X "$method" "https://${ES_HOST}:9200${path}" \
    -H 'content-type: application/json' "$@"
}
```

Then every call is flag-free over full HTTPS, e.g. `esadmin GET '/_cluster/health?pretty'`.

**Off an FPC host** (a workstation the `common` role never touched): trust the CA
once — copy `pki/ca.crt.pem` into the OS store (`update-ca-certificates`) or
`export CURL_CA_BUNDLE=~/fpc-internal-ca.pem` — or just SSH to an ES node.

### Maintenance cookbook

Use **`transient`** for temporary knobs (recovery throttle, allocation toggles,
node drains, watermark overrides): they auto-clear on a full-cluster restart, so
a reboot can never leave the cluster stuck throttled or cordoned. Durable policy
(awareness, replicas) is owned by the role as `persistent` — don't hand-edit it.
Always restore the knob and re-run `validate.yml` when done.

| Goal | Command |
|------|---------|
| Watch recovery progress | `esadmin GET '/_cat/recovery?active_only=true&v'` |
| Why is a shard unassigned? | `esadmin GET '/_cluster/allocation/explain?pretty'` |
| Disk used vs watermarks | `esadmin GET '/_cat/allocation?v'` |
| **Unthrottle recovery** | `esadmin PUT /_cluster/settings -d '{"transient":{"indices.recovery.max_bytes_per_sec":"-1"}}'` |
| Restore recovery throttle | `esadmin PUT /_cluster/settings -d '{"transient":{"indices.recovery.max_bytes_per_sec":null}}'` |
| Disable replica rebuild (pre-maintenance) | `esadmin PUT /_cluster/settings -d '{"transient":{"cluster.routing.allocation.enable":"primaries"}}'` |
| Re-enable allocation (after) | `esadmin PUT /_cluster/settings -d '{"transient":{"cluster.routing.allocation.enable":"all"}}'` |
| Retry shards that hit the failure limit | `esadmin POST '/_cluster/reroute?retry_failed=true'` |
| Drain/exclude a node (before removal) | `esadmin PUT /_cluster/settings -d '{"transient":{"cluster.routing.allocation.exclude._name":"es-phys-04-node-01"}}'` |
| Clear the node exclusion | `esadmin PUT /_cluster/settings -d '{"transient":{"cluster.routing.allocation.exclude._name":null}}'` |
| Temporarily raise the flood watermark | `esadmin PUT /_cluster/settings -d '{"transient":{"cluster.routing.allocation.disk.watermark.flood_stage":"97%"}}'` |
| Clear a flood read-only block (after freeing disk) | `esadmin PUT '/_all/_settings' -d '{"index.blocks.read_only_allow_delete":null}'` |
| Flush before a planned restart | `esadmin POST '/_flush'` |
| Inspect all overrides currently set | `esadmin GET '/_cluster/settings?flat_settings=true&pretty'` |

For snapshots, prefer `playbooks/backup.yml` (registers the `fpc-fs` filesystem
repo and takes a verified snapshot). Ad-hoc:
`esadmin PUT '/_snapshot/fpc-fs/manual-YYYYMMDD?wait_for_completion=false'`.

> After any drain/throttle/allocation change, **restore the default and confirm
> the override is gone** (`/_cluster/settings`). A node left in `exclude._name`
> or an allocation left at `none` is a common cause of "stuck yellow".

## Disk watermarks

| Watermark | Var                       | Default | Effect when crossed                         |
|-----------|---------------------------|---------|---------------------------------------------|
| low       | `es_disk_watermark_low`   | 85%     | stop allocating new shards to the node      |
| high      | `es_disk_watermark_high`  | 90%     | actively relocate shards off the node       |
| flood     | `es_disk_watermark_flood` | 95%     | indices go read-only (`read_only_allow_delete`) |

If a node floods, free space (or extend retention down) and clear the
read-only block once back under high. PCAP space is governed separately by
`arkime_free_space` and `arkime_pcap_retention_days` (oldest PCAP deleted first).

## Certificate and credential rotation

* **Internal CA / node + server certs.** Signed by the internal CA
  (`pki/ca.crt.pem`) via `community.crypto.x509_certificate` (ownca),
  `tls_cert_validity_days = 825`. To rotate a node/server cert, delete the local
  per-host cert under `pki/...`, re-run the role (delegates to localhost to
  re-sign, ships the cert, notifies the restart handler), one host at a time.
* **CA rotation** is a planned campaign: issue the new CA, distribute it to every
  node's trust (`ca.crt.pem`) and to the Arkime CA bundle and ldap-auth before
  switching leaf certs, then roll.
* **Secrets** (`es_bootstrap_password`, `es_arkime_writer_password`,
  `arkime_password_secret`, `arkime_server_secret`, `arkime_admin_password`,
  `ldap_bind_password`) live in Vault / AWX credentials and are handled
  `no_log: true`. Rotate by updating the vault value and re-running the owning
  role; rotate the digest break-glass admin after any emergency use
  (see [authentication.md](authentication.md)).

## Add or remove an Arkime recorder

**Add:** add the host to `arkime_recorders` with its `management_interface`,
`capture_interfaces`, and `nginx_server_name` (FQDN); run `site.yml --limit
<newhost>`. It registers as an Arkime node, fronted by its own Nginx; ES needs no
change. **Remove:** stop capture, let PCAP retention age out or archive it, then
decommission the host. No ES topology change.

## Add or remove an Elasticsearch host

**Add a data host:** add it to `elasticsearch_physical_hosts` (and to
`es_awareness_force_values`). Do **not** add it to `es_master_eligible_hosts`
(keep masters at exactly 3). Run `site.yml --limit <newhost>`; it joins and ES
rebalances shards onto the new failure domain. **Remove a data host:** drain it
first with allocation filtering
(`cluster.routing.allocation.exclude._name`/`._host` — see the ES CLI
administration cookbook) until it holds 0 shards,
then halt and decommission. Never remove a master host without first moving
master-eligibility to another host and confirming quorum.

## Change node density

Changing `elasticsearch_nodes_per_host` re-derives container limits and heaps.
Roll it **one host at a time** with `--limit`, waiting for green between hosts
(see [upgrades.md](upgrades.md) for the disable-allocation roll pattern). Confirm
the new N against [sizing.md](sizing.md) and the benchmark first.

## Routine maintenance (one host at a time)

1. Run `validate.yml` — confirm green before touching anything.
2. For ES work, disable replica allocation
   (`cluster.routing.allocation.enable: primaries`, via `esadmin` — see ES CLI
   administration) to avoid needless rebuild.
3. Drain/cordon as needed; do the work on a single host.
4. Bring it back, wait for green / 0 unassigned, re-enable allocation.
5. Re-run `validate.yml`. Only then proceed to the next host.

PCAP on a recorder is host-local: maintenance on one recorder does not affect
others, but capture is paused on that host for the window — schedule accordingly.
