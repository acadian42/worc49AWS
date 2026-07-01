# Official sources consulted

Primary vendor/upstream documentation used to design and pin this build. All
entries accessed **2026-06-24**. Versions/digests in `group_vars/all.yml` were
verified against these on the same date.

| Area | Topic | Source | URL | Accessed |
|------|-------|--------|-----|----------|
| Arkime | Settings reference (`authMode`, `userNameHeader`, `requiredAuthHeader`, `requiredAuthHeaderVal`, `userAuthIps`) | Arkime | https://arkime.com/settings | 2026-06-24 |
| Arkime | FAQ — upgrading to Arkime 6, `db.pl` upgrade | Arkime | https://arkime.com/faq | 2026-06-24 |
| Arkime | Arkime 6 release notes | Arkime | https://arkime.com/release-v6 | 2026-06-24 |
| Arkime | `config.ini` sample (auth + capture keys) | Arkime (GitHub) | https://github.com/arkime/arkime/blob/main/release/config.ini.sample | 2026-06-24 |
| Arkime | Official container image | Arkime | https://arkime.com/docker | 2026-06-24 |
| Elastic | Rolling upgrades (disable allocation, roll, re-enable) | Elastic | https://www.elastic.co/guide/en/elasticsearch/reference/8.19/rolling-upgrades.html | 2026-06-24 |
| Elastic | Snapshot and restore | Elastic | https://www.elastic.co/guide/en/elasticsearch/reference/8.19/snapshot-restore.html | 2026-06-24 |
| Elastic | Cluster-level shard allocation & awareness (force values) | Elastic | https://www.elastic.co/guide/en/elasticsearch/reference/8.19/modules-cluster.html | 2026-06-24 |
| Elastic | Disk-based shard allocation (watermarks) | Elastic | https://www.elastic.co/guide/en/elasticsearch/reference/8.19/modules-cluster.html#disk-based-shard-allocation | 2026-06-24 |
| Elastic | Important JVM/heap settings (compressed oops, sizing) | Elastic | https://www.elastic.co/guide/en/elasticsearch/reference/8.19/advanced-configuration.html#set-jvm-heap-size | 2026-06-24 |
| Elastic | Bootstrap checks & `cluster.initial_master_nodes` | Elastic | https://www.elastic.co/guide/en/elasticsearch/reference/8.19/modules-discovery-bootstrap-cluster.html | 2026-06-24 |
| Elastic | Official Elasticsearch container image | Elastic | https://www.docker.elastic.co/ | 2026-06-24 |
| community.docker | `docker_compose_v2` module | Ansible Galaxy docs | https://docs.ansible.com/ansible/latest/collections/community/docker/docker_compose_v2_module.html | 2026-06-24 |
| AWX / ansible-builder | Execution Environments | AWX docs | https://docs.ansible.com/projects/awx/en/latest/userguide/execution_environments.html | 2026-06-24 |
| AWX / ansible-builder | Building execution environments | Ansible Builder docs | https://docs.ansible.com/projects/builder/en/stable/ | 2026-06-24 |
| AWX / ansible-builder | Default AWX EE base image | ansible/awx-ee (GitHub) | https://github.com/ansible/awx-ee | 2026-06-24 |
| Vagrant / VMware | Vagrant documentation | HashiCorp | https://developer.hashicorp.com/vagrant/docs | 2026-06-24 |
| Vagrant / VMware | VMware provider plugin | HashiCorp | https://developer.hashicorp.com/vagrant/docs/providers/vmware | 2026-06-24 |
| nginx | `ngx_http_auth_request_module` (`auth_request`) | nginx | https://nginx.org/en/docs/http/ngx_http_auth_request_module.html | 2026-06-24 |
| nginx | `proxy_set_header` / header handling | nginx | https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_set_header | 2026-06-24 |
| nginx | HSTS / `add_header` (`ngx_http_headers_module`) | nginx | https://nginx.org/en/docs/http/ngx_http_headers_module.html | 2026-06-24 |
| caltechads | nginx-ldap-auth-service (LDAPS auth sidecar) | caltechads (GitHub) | https://github.com/caltechads/nginx-ldap-auth-service | 2026-06-24 |
| caltechads | nginx-ldap-auth-service image | Docker Hub | https://hub.docker.com/r/caltechads/nginx-ldap-auth-service | 2026-06-24 |
