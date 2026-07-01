# Upgrades

All upgrades are **rolling, one host at a time**, image-digest driven, and
preceded by a snapshot. Images are delivered as pinned digests
(`load_from_archive` or `registry`), so an upgrade is fundamentally a
**digest-pin change** followed by a controlled roll.

## Digest-pin update process

1. Resolve the new digest for the target version:
   `docker buildx imagetools inspect <repo>:<version>` → `sha256:...`.
2. Update the pin in `group_vars/all.yml` (`*_image_digest`) and bump the
   matching `*_version`. Record old → new in the change log and
   `docs/_sources/`.
3. Build/pull on the build host, `docker save` → ship → `docker load`
   (`docker_engine` role), or push to the private registry.
4. Roll per the procedures below. Compose runs `pull: never`, so a host runs
   exactly the loaded digest — no surprise drift.

## Rolling Elasticsearch upgrade (minor / patch within 8.x)

ES supports rolling upgrades for minor/patch versions within the same major.
Do **one node/host at a time**:

1. **Snapshot first.** Take a cluster snapshot to the snapshot repo
   (`es_snapshot_repo_path`); see [disaster-recovery.md](disaster-recovery.md).
2. **Disable replica allocation** to avoid pointless rebuilds while a node is
   down:

   ```json
   PUT /_cluster/settings
   { "persistent": { "cluster.routing.allocation.enable": "primaries" } }
   ```

3. (Optional) `POST /_flush` to speed recovery.
4. **Stop one node**, update its image digest, restart it (the
   `elasticsearch_cluster` role + `Restart elasticsearch nodes` handler does this
   when you re-run with `--limit <host>`). The bootstrap guard ensures the
   re-imaged/restarted node **rejoins** — it never re-bootstraps.
5. **Re-enable allocation** and wait for green / 0 unassigned:

   ```json
   PUT /_cluster/settings
   { "persistent": { "cluster.routing.allocation.enable": null } }
   ```

6. Run `validate.yml`. Only when green, proceed to the next host. Upgrade the
   **master-eligible hosts last** to keep quorum stable during the roll.

> Major-version jumps (e.g. 7.x → 8.x) are **not** a simple rolling minor: follow
> Elastic's major-upgrade guidance (deprecation check, possible reindex). This
> platform targets 8.19.x.

## Arkime upgrade

* **Supported lineage: ≥ 5.2.0 → 6.x.** Upgrade *to* Arkime 6 only from a 5.x
  that has followed Arkime's "upgrading to 6" instructions; do not jump from very
  old releases. This build targets **v6.5.0**.
* **Database schema upgrade with `db.pl`.** After updating the Arkime image
  digest, run the schema upgrade (idempotent — only acts if needed):

  ```bash
  db.pl https://<ES-host>:9200 info            # show current DB version
  db.pl https://<ES-host>:9200 upgradenoprompt --ifneeded
  ```

  The gated init/upgrade flow in the recorder role wraps this; it is guarded by
  `arkime_force_init` / `confirm_destroy` so it never runs by accident.
* **Roll recorders one at a time:** update the digest, re-run `site.yml --limit
  <recorder>` (the `Recreate arkime services` handler recreates capture+viewer),
  confirm capture resumes with no drops, then the next.
* Run `db.pl upgrade` **once** against the cluster after the ES-facing version
  moves; viewers on the new image expect the new schema.

## Rollback boundaries

* **Elasticsearch: no in-place downgrade.** ES does not support downgrading a
  node to an earlier version once started on a newer one. Rollback = **restore
  the pre-upgrade snapshot** onto a cluster of the previous version. This is why
  step 1 (snapshot) is mandatory.
* **Arkime viewer/capture** can be rolled back to the previous digest **only if
  the DB schema was not upgraded** (or the schema is still compatible). Once
  `db.pl upgrade` has run, the SPI schema may be ahead of the old binary —
  rollback then means snapshot-restore of the ES indices, not just a digest swap.
* **Never delete data volumes** as part of a rollback. Re-image and rejoin
  (see [disaster-recovery.md](disaster-recovery.md)); the bootstrap guard
  prevents accidental re-bootstrap.
