# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses date-based releases.

## [Unreleased]

### Added
- Initial repository scaffold: `ansible.cfg`, `requirements.yml`, lint configs, `.gitignore`,
  `.gitleaks.toml`, README.
- Canonical variable contract in `inventories/production/group_vars/` and Vagrant lab overrides.
- Production inventory example and Vagrant functional-profile inventory.
- Roles: `common`, `docker_engine`, `elasticsearch_host`, `elasticsearch_cluster`, `arkime_recorder`,
  `nginx_ldap_proxy`, `validation`.
- Playbooks: `site`, `preflight`, `deploy_elasticsearch`, `initialize_arkime`, `deploy_recorders`,
  `deploy_nginx`, `validate`, `upgrade`, `backup`, `recover`.
- AWX execution environment (schema v3) and objects-as-code (job templates + workflow with approval
  nodes and a density survey).
- Vagrant + VMware lab (functional + full-topology profiles) and test/verification scaffolding.

### Decisions (see plan for full rationale)
- Pin Arkime **v6.5.0** (digest) and Elasticsearch **8.19.17**; verified 2026-06-24.
- Default `elasticsearch_nodes_per_host: 3`; 4/5 must win a benchmark before adoption (125 GiB hosts do
  not reach the 30 GiB heap "sweet spot" the 256 GB predecessor relied on).
- Per-host Docker Compose v2 (no Kubernetes/Swarm); host networking for ES and capture.
- Nginx `auth_request` → AD/LDAPS via `caltechads/nginx-ldap-auth-service`; Arkime `authMode=header+digest`
  with `userAuthIps` locked to the proxy/loopback IP (Arkime 6.5.0 checks the connecting IP).
- Image delivery defaults to `load_from_archive` (build on VM → save → ship → load); private registry optional.
