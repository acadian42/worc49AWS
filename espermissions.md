Subject: Elasticsearch administrator access model — recommended permissions scope

Team,

Following the discussion about Elasticsearch administrators requesting sudo/root access on the ES hosts, I've put together a recommended permissions model that gives them everything they need to operate the cluster without granting standing root. The short version: ES `superuser` inside the cluster covers day-to-day administration, and a narrowly scoped sudoers file covers the handful of operations that genuinely require touching the host.

--- Elasticsearch role assignments ---

Primary recommendation: assign the built-in `superuser` role, bound to each administrator's individual SSO identity. No shared accounts, no shared API keys.

If we want to compose from granular built-ins instead of granting `superuser`, the equivalent set is:

- manage
- manage_security
- manage_index_templates
- manage_ilm
- manage_pipeline
- manage_snapshot
- manage_transform
- manage_ml
- manage_watcher
- monitor
- read_ccr

This covers all index, template, ILM, ingest, snapshot, transform, ML, watcher, CCR, cluster-settings, user/role, API-key, and monitoring operations. Roughly 90% of what an ES administrator does day-to-day happens through these APIs and never touches the host OS.

--- Unix/Linux host permissions ---

1. Individual user accounts only. Each administrator gets their own account, authenticated via the central directory (AD/LDAP/SSO). No shared `esadmin` login. No SSH access to the `elasticsearch` service account.

2. Group membership. Add each administrator to the `elasticsearch` Unix group (created automatically by the package install). With default file modes of 0640 owned by `elasticsearch:elasticsearch`, this grants read access to:
   - /etc/elasticsearch/  (configuration, role files, realm configuration)
   - /var/log/elasticsearch/  (log files)

3. Data directories remain locked down. /var/lib/elasticsearch/ stays as `elasticsearch:elasticsearch` mode 0700. Administrators should never read or modify shard files directly.

4. Configuration writes go through configuration management. Changes to elasticsearch.yml, jvm.options, log4j2.properties, and TLS material should flow through Ansible/Puppet/Chef with peer review rather than direct edits. If direct edits are unavoidable for specific files, use POSIX ACLs to grant write access to named individuals rather than loosening group permissions:

   setfacl -m u:<username>:rw /etc/elasticsearch/elasticsearch.yml

--- Scoped sudoers file ---

The following rules cover every legitimate host-level operation an ES administrator performs. File location: /etc/sudoers.d/elasticsearch-admin (owner root:root, mode 0440, validated with `visudo -c`).

# /etc/sudoers.d/elasticsearch-admin

Cmnd_Alias ES_SERVICE = /bin/systemctl start elasticsearch.service, \
                        /bin/systemctl stop elasticsearch.service, \
                        /bin/systemctl restart elasticsearch.service, \
                        /bin/systemctl reload elasticsearch.service, \
                        /bin/systemctl status elasticsearch.service, \
                        /bin/journalctl -u elasticsearch.service, \
                        /bin/journalctl -u elasticsearch.service -f, \
                        /bin/journalctl -u elasticsearch.service --since *

Cmnd_Alias ES_TOOLS = /usr/share/elasticsearch/bin/elasticsearch-keystore, \
                      /usr/share/elasticsearch/bin/elasticsearch-keystore *, \
                      /usr/share/elasticsearch/bin/elasticsearch-users, \
                      /usr/share/elasticsearch/bin/elasticsearch-users *, \
                      /usr/share/elasticsearch/bin/elasticsearch-certutil *, \
                      /usr/share/elasticsearch/bin/elasticsearch-reset-password *, \
                      /usr/share/elasticsearch/bin/elasticsearch-saml-metadata *, \
                      /usr/share/elasticsearch/bin/elasticsearch-service-tokens *, \
                      /usr/share/elasticsearch/bin/elasticsearch-shard *, \
                      /usr/share/elasticsearch/bin/elasticsearch-node *

Cmnd_Alias ES_PLUGINS = /usr/share/elasticsearch/bin/elasticsearch-plugin list, \
                        /usr/share/elasticsearch/bin/elasticsearch-plugin install *, \
                        /usr/share/elasticsearch/bin/elasticsearch-plugin remove *

Cmnd_Alias ES_DIAG = /usr/bin/jcmd, /usr/bin/jstack, /usr/bin/jmap, /usr/bin/jstat

%esadmins  ALL=(root)          NOPASSWD: ES_SERVICE
%esadmins  ALL=(elasticsearch) NOPASSWD: ES_TOOLS, ES_PLUGINS, ES_DIAG

Defaults:%esadmins  !visiblepw, requiretty, log_input, log_output, \
                    logfile=/var/log/sudo-esadmin.log

Three details worth flagging:

- ES CLI tools (keystore, users, certutil, etc.) are sudo'd as the `elasticsearch` user, not root. Running them as root creates root-owned files in the keystore and data directories and breaks the service.
- Absolute paths and full unit names (elasticsearch.service) are required. Wildcards in systemctl commands are an escape vector.
- elasticsearch-plugin installs arbitrary code that executes inside the ES JVM. Plugin installation should be tied to a change ticket; the wildcard can be removed if we want a tighter gate.

--- What this covers ---

With ES `superuser` plus this sudoers file, administrators can:

- Perform all cluster, index, security, and data management through the API
- Start, stop, restart, and reload the elasticsearch service
- Read service logs via journalctl and directly from /var/log/elasticsearch
- Manage the keystore (snapshot repo credentials, SAML/OIDC secrets, etc.)
- Manage native-realm users and reset passwords from the CLI
- Generate and manage TLS certificates via elasticsearch-certutil
- Install, list, and remove plugins
- Run JVM diagnostics (heap dumps, thread dumps) as the ES process owner
- Execute disaster-recovery tools (elasticsearch-node, elasticsearch-shard) when needed

--- What this excludes, and why ---

The sudoers file deliberately does not grant:

- General sudo or membership in wheel/sudo
- Shell access as root or as the elasticsearch user
- Package management (OS patching, ES version upgrades) — this is a separately change-controlled operation
- Kernel tuning, ulimits, firewall, disk provisioning — these are sysadmin responsibilities, not ES administration
- Editors or pagers via sudo (vi, less, more, man all have shell escapes)

For genuine emergencies (loss of quorum requiring unsafe-bootstrap, forensic investigation, attaching a debugger to a hung JVM), a separately controlled break-glass account with full session recording should be used on a per-incident basis rather than granting standing privilege.

--- Audit and review ---

- log_input and log_output are enabled for the esadmins group; sudo session logs ship to the SIEM
- Alerts configured for invocations of elasticsearch-node, elasticsearch-shard, and elasticsearch-plugin install
- Sudoers file reviewed quarterly to account for new CLI tools introduced in ES point releases

--- Proposal ---

I'd recommend we run with this model for 60–90 days and review the sudo audit log at the end of that window. If there's a category of operation the administrators legitimately needed that this configuration didn't cover, we add it. Based on prior experience, the log will show very few sudo invocations and no gaps — at which point the case for standing root access is settled on evidence rather than opinion.

