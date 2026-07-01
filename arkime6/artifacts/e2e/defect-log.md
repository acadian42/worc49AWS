## Defect 1 — common role: no apt cache refresh
- Stage: deploy_elasticsearch (common role), AWX job 8
- Symptom: apt install chrony failed: 404 fetching tzdata-legacy_2025b (.deb superseded; stale box apt cache)
- Root cause: repository defect — common role installed packages without `apt update`
- Fix: roles/common/tasks/main.yml — add Debian apt update_cache (cache_valid_time 3600) before install
- Type: repository defect

## Defect 0 — EE build (awx/execution-environment.yml, awx/bindep.txt)
- Symptom: ansible-builder build failed (a) ansible-core 2.21.1 unavailable on base py3.9; (b) ovirt sdk wheels fail
- Root cause: repository defect — EE pinned ansible-core 2.21.1 on awx-ee:24.6.1 (py3.9) base, wrong package_manager_path (microdnf), and introspected base collections' uncompilable deps
- Fix: add python_interpreter python3.12 + python3.12-pip, set package_manager_path /usr/bin/dnf, exclude ovirt python deps
- Type: repository defect

## Defect 2 — docker_engine: deb822_repository needs python3-debian
- Stage: deploy_elasticsearch (docker_engine role), AWX job 12
- Symptom: "python3-debian is not installed, and install_python_debian is False"
- Root cause: repository defect — install_debian.yml uses ansible.builtin.deb822_repository without ensuring python3-debian present
- Fix: add python3-debian to the prerequisite apt install
- Type: repository defect

## Defect 3 — docker_engine: daemon.json had comment header (invalid JSON)
- Stage: deploy_elasticsearch (docker_engine), AWX job 16
- Symptom: dockerd: "unable to configure the Docker daemon with file /etc/docker/daemon.json: invalid character '#'"
- Root cause: repository defect — daemon.json.j2 began with {{ ansible_managed | comment }} (# header); JSON forbids comments
- Fix: daemon.json.j2 emits pure JSON (Jinja comment only)
- Type: repository defect

## Defect 4 — elasticsearch_cluster/validation: API scheme hardcoded https
- Stage: would fail health/security/validation when es_http_tls=false
- Root cause: repository defect — role ignored es_http_tls and always used https + ca_path
- Fix: scheme + validate_certs + ca_path now honor es_http_tls (es_api_scheme/validation_es_scheme)
- Lab note: E2E sets es_http_tls=false to avoid a cross-job ephemeral-CA problem (CA is generated on the ephemeral AWX EE pod per job); transport TLS stays on. Documented as a production limitation (see report).
- Type: repository defect

## Defect 5 — initialize_arkime ran before the recorder had Docker/the Arkime image
- Stage: workflow ordering (init before recorders; db.pl runs in a container on the recorder)
- Root cause: repository defect — initialize_arkime.yml only ran arkime init tasks; the recorder had no Docker/image yet
- Fix: initialize_arkime.yml now runs common + docker_engine (prepares host + pulls image) before db.pl
- Type: repository defect

## Defect 6 — docker_engine: docker_image_pull invalid 'source' param
- Stage: deploy_elasticsearch (docker_engine deliver_images, registry mode), AWX job 20
- Symptom: "Unsupported parameters for (community.docker.docker_image_pull) module: source"
- Root cause: repository defect — used legacy docker_image's 'source: pull'; docker_image_pull uses 'pull: always|not_present'
- Fix: pull: not_present
- Type: repository defect

## Defect 7 — es certs: empty-string CA passphrase passed to unencrypted key
- Stage: deploy_elasticsearch (elasticsearch_cluster certs.yml), AWX job 24
- Symptom: "Wrong or empty passphrase provided for private key"
- Root cause: repository defect — ownca_privatekey_passphrase used `default(omit)`, which does NOT omit an empty string (internal_ca_key_passphrase=''); an empty passphrase was sent to an unencrypted CA key
- Fix: conditional omit when passphrase is '' (matches pki.yml/nginx certs.yml)
- Type: repository defect

## Defect 8 — ES JVM GC log path was relative -> crash loop
- Stage: deploy_elasticsearch health gate (ES containers crash-looping), AWX job 28
- Symptom: ES exits at JVM launch: "Error opening log file 'logs/gc.log': No such file or directory"; health API connection refused x60
- Root cause: repository defect — es_gc_log_path/es_heap_dump_path were relative; the JVM heap-sizing probe cannot open a relative -Xlog file
- Fix: absolute container paths (/usr/share/elasticsearch/logs/gc.log, /usr/share/elasticsearch/data) in both e2e and production group_vars
- Type: repository defect (affects production too)

## Process bug — resync updated the project but NOT the SCM inventory source
- Symptom: group_vars edits (es_http_tls, absolute gc path, etc.) never reached AWX jobs; ES kept crash-looping on the OLD gc.log path despite the fix being committed
- Root cause: AWX SCM inventory source caches group_vars from its last sync; tests/e2e/resync.py only updated the project
- Fix: resync.py now updates the project AND the inventory source every iteration
- Type: test-harness fix

## Defect 9 — arkime init: CA mount on http + db.pl upgrade needs piped UPGRADE
- Stage: initialize_arkime (arkime_recorder init.yml), AWX job 40
- Symptom 1: db.pl/admin failed — CA mount of a non-existent host path (CA not shipped before init) on an http endpoint
- Symptom 2: db.pl upgrade --ilm prompts "Type UPGRADE" -> failed on closed stdin
- Root cause: repository defects — CA mount/--cacert/caTrustFile unconditional; upgrade not piped
- Fix: CA mount/--cacert/caTrustFile gated on arkime_es_scheme==https; pipe UPGRADE via stdin like init pipes INIT
- Type: repository defect

## Defect 10 — recorder used EMPTY ES writer password (db.pl 401; Arkime ES auth would also fail)
- Stage: initialize_arkime db.pl init (job 48); also affects recorder capture/viewer ES auth
- Symptom: rendered "--esuser arkime_writer:" (empty) -> ES 401 Unauthorized
- Root cause: repository defect — arkime_es_password derived from es_arkime_writer_password, which is defined only in the ES group_vars (out of scope on recorder hosts)
- Fix: source from the globally-available vault var first: vault_es_arkime_writer_password | default(es_arkime_writer_password | default(''))
- Type: repository defect

## Defect 11 — init wrote temp config.ini to a non-existent dir
- Stage: initialize_arkime "Create a temporary config.ini" (gated flow doesn't run recorder main.yml that creates arkime_config_path)
- Fix: ensure arkime_config_path exists in init.yml before writing the bootstrap config
- Type: repository defect

## Defect 12 — Arkime viewer crashed: caTrustFile pointed at a directory (EISDIR) on http ES
- Stage: deploy_recorders (arkime-viewer unhealthy), AWX job 57
- Symptom: viewer crash "EISDIR: illegal operation on a directory, read" in Auth.initialize (caTrustFile); never listens on 8005
- Root cause: repository defect — config.ini always set caTrustFile and the compose always mounted the CA, even for an http ES endpoint; the host CA path had become a directory (docker -v of a nonexistent file in earlier runs)
- Fix: gate caTrustFile (config.ini.j2), the CA volume mounts (arkime-compose.yml.j2), and CA shipping (main.yml) on arkime_es_scheme=='https'
- Type: repository defect

## Defect 13 — nginx crash-loop: cap_drop ALL removed caps its entrypoint needs
- Stage: deploy_nginx (fpc-nginx Restarting), AWX job 67
- Symptom: nginx [emerg] chown("/var/cache/nginx/client_temp") Operation not permitted
- Root cause: repository defect — nginx container dropped ALL caps and added only NET_BIND_SERVICE; the official nginx entrypoint needs CHOWN/SETUID/SETGID/DAC_OVERRIDE
- Fix: add CHOWN, SETUID, SETGID, DAC_OVERRIDE (plus NET_BIND_SERVICE)
- Type: repository defect

## Defect 14 — ldap-auth filters used wrong placeholder/format
- Stage: deploy_nginx (fpc-ldap-auth Restarting), AWX job 67
- Symptom: pydantic ValidationError: "ldap_authorization_filter does not use the {username} placeholder"
- Root cause: repository defect — LDAP_AUTHORIZATION_FILTER had no {username}; LDAP_GET_USER_FILTER used %(username)s (caltechads requires {username})
- Fix: authorization filter is now an overridable var requiring {username}; user filter uses {username} (prod + e2e)
- Type: repository defect

## Added — lab-only OpenLDAP (playbooks/e2e_lab_ldap.yml) + workflow node
- Two-VM constraint: a bitnami/openldap container (seeded user) runs on the recorder so the sidecar has a backend. Gated on fpc_lab. Inserted between recorders and nginx in the FPC-E2E workflow.

## Defect 15 — validation role: dotted _cat key broke selectattr
- Stage: validate (master-eligible assertion), AWX job 98
- Symptom: "object of type 'dict' has no attribute 'node'" (selectattr('node.role',...) treated the dotted _cat key as nested)
- Root cause: repository defect in the validation role
- Fix: count master-eligible nodes from the _nodes API roles list (selectattr('roles','contains','master'))
- Type: repository defect (test/validation code)

## MILESTONE — full stack deployed via AWX
- workflow job 84: preflight, deploy_elasticsearch, [approval], initialize_arkime, deploy_recorders, lab_ldap, deploy_nginx ALL succeeded. Only the validate playbook had the bug above.

## Defect 16 — validation shard-colocation check failed on single-host lab (expected)
- Stage: validate (shard awareness best-effort), AWX job 110
- Symptom: "two copies on a single physical host" — true & unavoidable with one failure domain (some indices carry replicas)
- Fix: gate the shard-colocation check on (elasticsearch_physical_hosts | length) > 1; documented that the 2-VM topology does not validate cross-host awareness
- Type: repository defect (validation correctness for single-host)

## Defect 17 — ldap-auth crash: CA cert env set for plain ldap://
- Symptom: pydantic "ldap_ca_cert_name does not exist in ldap_ca_cert_dir" -> sidecar crash-loop -> nginx 500 (auth subrequest 502)
- Fix: only emit LDAP_CA_CERT_DIR/NAME for ldaps:// or StartTLS
- Type: repository defect

## Defect 18 — firewall blocked port 80 (HTTPS redirect unreachable)
- Symptom: http://recorder/ -> 000 (ufw allowed only 443)
- Fix: allow tcp/80 from analyst_cidrs on recorders when nginx_redirect_http
- Type: repository defect

## Defect 19 — validate summary/arkime undefined vars
- Symptom: 'nginx_version'/'arkime_viewer_port' undefined in validate
- Fix: summary uses nginx_image/ldap_auth_image; validation role defines arkime_viewer_port default
- Type: repository defect (validation code)

## Defect 20 — validation auth probe failed TLS verify (internal-CA cert)
- Symptom: validate auth check "SSL: CERTIFICATE_VERIFY_FAILED" (Python urllib ignores OS trust store)
- Fix: auth status-code probes use validate_certs:false (TLS validity verified separately)
- Type: repository defect (validation code)

## Defect 21 — ldap-auth bound to container hostname, not loopback
- Symptom: sidecar listened on 127.0.2.1:8888 (container hostname); nginx 127.0.0.1:8888 subrequest refused -> nginx 500
- Fix: set HOST=127.0.0.1 in the sidecar env
- Also: form-auth returns 302 (login redirect) for unauthenticated requests; validation + verify now treat 302/401/403 as "denied"
- Type: repository defect

## Defect 22 — ldap-auth listen host set via CLI flag, not env
- Symptom: HOST env ignored; sidecar still bound container hostname (127.0.2.1); nginx 500 persisted
- Fix: override container command to "nginx-ldap-auth start --host 127.0.0.1 --port 8888"
- Type: repository defect

## Defect 23 — validate auth probes followed redirect / narrow status set
- Symptom: unauth/spoof checks saw 200 (login page, redirect followed) then 400 (ansible-uri framing of the forged-header request)
- Reality (verified with curl): unauthenticated -> 302 login redirect; forged remote-user header -> stripped, request denied. Direct viewer bypass blocked. Security properties HOLD.
- Fix: follow_redirects:none on the probes; treat 302/400/401/403 all as "denied" (not authenticated through to the viewer)
- Type: repository defect (validation code)

## Defects 22-26 — Nginx<->LDAP sidecar integration (caltechads)
- 22: sidecar bound container hostname -> command "--host 127.0.0.1"
- 23: in-memory sessions across 2 workers -> "--workers 1"
- 24: login (/auth) + /check-auth must send X-Cookie-Name AND X-Cookie-Domain so the issued session cookie matches validation (added; aligned to the sidecar's canonical nginx config)
- 25: lab login user must sit at uid=<u>,<base> (sidecar constructs the bind DN) -> ldapadd uid=analyst,dc=lab,dc=local; uid-based filters
- 26: test artifact — Arkime redirects / for logged-in users; the authenticated check must hit /api/user (200), not / (302)
- RESULT: valid LDAP login reaches the viewer (200); invalid denied; emergency digest works; LDAP outage fails closed. (Group->role auto-mapping remains a documented limitation: lab LDAP has no memberOf overlay.)

## Defect 27 — initialize_arkime re-wiped the DB on every forced run (idempotence)
- v1 parse bug: regex_search version parse evaluated false -> init still re-ran. Fixed with `is search('DB Version:\s*[0-9]')`.
- Symptom: arkime_force_init=true ran db.pl init unconditionally -> destructive re-init each run
- Fix: db.pl init now runs only when the schema is ABSENT (DB Version < 0) or arkime_reinit=true; arkime_force_init is the safety gate that ALLOWS init, not a force-wipe
- Type: repository defect (idempotence / data-safety)

## Defect 28 — lab_ldap seed raced freshly-started OpenLDAP (clean rebuild)
- Symptom: on a from-scratch rebuild, ldapadd ran before slapd accepted binds / base DN existed -> task failed
- Fix: retry the seed (until rc in [0,68], 15x5s)
- Type: test-harness robustness (lab LDAP only)
