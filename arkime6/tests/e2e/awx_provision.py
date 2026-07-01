#!/usr/bin/env python3
"""
Idempotently create the FPC-E2E AWX objects via the AWX REST API.

Reads (all gitignored, mode 0600):
  .e2e-state/awx_token      AWX OAuth2 token (Bearer)
  .e2e-state/e2e_ssh_key    dedicated machine-credential private key
  .e2e-state/secrets.env    lab secret values (injected via a custom credential)
  .e2e-state/vm_ips.env     discovered NAT IPs (reference only; inventory is SCM)

Creates, all prefixed FPC-E2E:
  Organization, Project (git SCM), Execution Environment, Machine credential,
  custom "FPC-E2E Secrets" credential type + credential, Inventory + SCM source,
  Job Templates (preflight/deploy_elasticsearch/initialize_arkime/deploy_recorders/
  deploy_nginx/validate), and a Workflow Job Template with an approval gate before
  Arkime DB init.

No secret VALUES are printed. Records created object ids to
.e2e-state/awx_objects.json and a sanitized copy to artifacts/e2e/awx_objects.json.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE = os.path.join(ROOT, ".e2e-state")
ART = os.path.join(ROOT, "artifacts", "e2e")
AWX = os.environ.get("AWX_URL", "http://127.0.0.1:30080")
GIT_URL = os.environ.get("E2E_GIT_URL", "git://192.168.184.1:9418/fpc_production_build_arikme")
BRANCH = os.environ.get("E2E_BRANCH", "e2e-smoke")
EE_IMAGE = os.environ.get("E2E_EE_IMAGE", "fpc-e2e-ee:1.0")
PREFIX = "FPC-E2E"

TOKEN = open(os.path.join(STATE, "awx_token")).read().strip()
SSH_KEY = open(os.path.join(STATE, "e2e_ssh_key")).read()
SECRETS = {}
for line in open(os.path.join(STATE, "secrets.env")):
    line = line.strip()
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        SECRETS[k] = v

created = {}


def api(method, path, body=None, ok=(200, 201, 202, 204)):
    url = path if path.startswith("http") else AWX + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        if e.code not in ok:
            print(f"  ! {method} {path} -> {e.code}: {raw[:400]}")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw}


def find(endpoint, name):
    _, d = api("GET", f"{endpoint}?name={urllib.parse.quote(name)}")
    for r in d.get("results", []):
        if r.get("name") == name:
            return r
    return None


def ensure(endpoint, name, payload, patch=True):
    existing = find(endpoint, name)
    if existing:
        if patch:
            api("PATCH", f"{endpoint}{existing['id']}/", payload)
        print(f"  = {endpoint} '{name}' (id {existing['id']})")
        return existing["id"]
    st, d = api("POST", endpoint, dict(payload, name=name))
    if "id" not in d:
        print(f"  ! failed to create {endpoint} '{name}': {st} {str(d)[:300]}")
        sys.exit(1)
    print(f"  + {endpoint} '{name}' (id {d['id']})")
    return d["id"]


import urllib.parse  # noqa: E402

print("== Organization ==")
org = ensure("/api/v2/organizations/", f"{PREFIX} Org", {"description": "FPC end-to-end smoke test"})
created["organization"] = org

print("== Execution Environment ==")
ee = ensure("/api/v2/execution_environments/", f"{PREFIX} EE",
            {"image": EE_IMAGE, "pull": "never", "organization": org})
created["execution_environment"] = ee

print("== Project (git SCM) ==")
proj = ensure("/api/v2/projects/", f"{PREFIX} Project", {
    "organization": org, "scm_type": "git", "scm_url": GIT_URL, "scm_branch": BRANCH,
    "scm_clean": True, "scm_delete_on_update": False, "scm_update_on_launch": False,
    "default_environment": ee,
})
created["project"] = proj
# trigger sync + poll
print("   syncing project ...")
api("POST", f"/api/v2/projects/{proj}/update/")
for _ in range(60):
    _, p = api("GET", f"/api/v2/projects/{proj}/")
    s = p.get("status")
    if s in ("successful", "failed", "error", "canceled"):
        print(f"   project status: {s}")
        break
    time.sleep(3)

print("== Machine credential ==")
_, ct = api("GET", "/api/v2/credential_types/?name=Machine")
machine_ct = ct["results"][0]["id"]
mcred = ensure("/api/v2/credentials/", f"{PREFIX} Machine", {
    "organization": org, "credential_type": machine_ct,
    "inputs": {"username": "vagrant", "ssh_key_data": SSH_KEY,
               "become_method": "sudo", "become_username": "root"},
})
created["machine_credential"] = mcred

print("== Custom secrets credential type + credential ==")
fields = [
    ("vault_es_bootstrap_password", "VAULT_ES_BOOTSTRAP"),
    ("vault_es_arkime_writer_password", "VAULT_ES_ARKIME_WRITER"),
    ("vault_arkime_password_secret", "VAULT_ARKIME_PWSECRET"),
    ("vault_arkime_server_secret", "VAULT_ARKIME_SERVERSECRET"),
    ("vault_arkime_admin_password", "VAULT_ARKIME_ADMIN"),
    ("vault_ldap_bind_password", "VAULT_LDAP_BIND"),
    ("vault_ldap_auth_session_secret", "VAULT_LDAP_SESSION"),
]
ct_inputs = {"fields": [{"id": f, "label": f, "secret": True} for f, _ in fields]}
ct_injectors = {"extra_vars": {f: "{{ " + f + " }}" for f, _ in fields}}
sec_ct = ensure("/api/v2/credential_types/", f"{PREFIX} Secrets",
                {"kind": "cloud", "inputs": ct_inputs, "injectors": ct_injectors})
created["secrets_credential_type"] = sec_ct
sec_inputs = {f: SECRETS[envk] for f, envk in fields}
scred = ensure("/api/v2/credentials/", f"{PREFIX} Secrets", {
    "organization": org, "credential_type": sec_ct, "inputs": sec_inputs}, patch=True)
created["secrets_credential"] = scred

print("== Inventory + SCM source ==")
inv = ensure("/api/v2/inventories/", f"{PREFIX} Inventory", {"organization": org})
created["inventory"] = inv
src = find(f"/api/v2/inventories/{inv}/inventory_sources/", f"{PREFIX} Source")
src_payload = {
    "source": "scm", "source_project": proj, "source_path": "inventories/e2e/hosts.yml",
    "overwrite": True, "overwrite_vars": True, "update_on_launch": False,
    "execution_environment": ee, "inventory": inv,
}
if src:
    api("PATCH", f"/api/v2/inventory_sources/{src['id']}/", src_payload)
    src_id = src["id"]
    print(f"  = inventory_source (id {src_id})")
else:
    st, d = api("POST", f"/api/v2/inventories/{inv}/inventory_sources/", dict(src_payload, name=f"{PREFIX} Source"))
    src_id = d["id"]
    print(f"  + inventory_source (id {src_id})")
created["inventory_source"] = src_id
print("   syncing inventory source ...")
api("POST", f"/api/v2/inventory_sources/{src_id}/update/")
for _ in range(40):
    _, s = api("GET", f"/api/v2/inventory_sources/{src_id}/")
    st = s.get("status")
    if st in ("successful", "failed", "error", "canceled"):
        print(f"   inventory source status: {st}")
        break
    time.sleep(3)
_, hosts = api("GET", f"/api/v2/inventories/{inv}/hosts/")
print(f"   inventory hosts: {[h['name'] for h in hosts.get('results', [])]}")

print("== Job Templates ==")
jt_defs = [
    ("preflight", "playbooks/preflight.yml", {}),
    ("deploy_elasticsearch", "playbooks/deploy_elasticsearch.yml", {}),
    ("initialize_arkime", "playbooks/initialize_arkime.yml", {"arkime_force_init": True}),
    ("deploy_recorders", "playbooks/deploy_recorders.yml", {}),
    ("lab_ldap", "playbooks/e2e_lab_ldap.yml", {}),
    ("deploy_nginx", "playbooks/deploy_nginx.yml", {}),
    ("validate", "playbooks/validate.yml", {}),
]
jt_ids = {}
for short, playbook, extra in jt_defs:
    name = f"{PREFIX} {short}"
    payload = {
        "job_type": "run", "inventory": inv, "project": proj, "playbook": playbook,
        "execution_environment": ee, "organization": org, "verbosity": 1,
        "allow_simultaneous": False, "ask_variables_on_launch": False,
        "become_enabled": True,
        "extra_vars": json.dumps(extra) if extra else "",
    }
    jid = ensure("/api/v2/job_templates/", name, payload)
    jt_ids[short] = jid
    # attach machine + secrets credentials (idempotent associate)
    for cid in (mcred, scred):
        api("POST", f"/api/v2/job_templates/{jid}/credentials/", {"id": cid})
created["job_templates"] = jt_ids

print("== Workflow Job Template ==")
wf = ensure("/api/v2/workflow_job_templates/", f"{PREFIX} Workflow", {
    "organization": org, "inventory": inv, "allow_simultaneous": False,
    "description": "preflight -> ES -> [approval] init -> recorders -> nginx -> validate",
})
created["workflow"] = wf
# Rebuild the node graph cleanly: delete existing nodes, then recreate in order.
_, existing_nodes = api("GET", f"/api/v2/workflow_job_templates/{wf}/workflow_nodes/?page_size=200")
for n in existing_nodes.get("results", []):
    api("DELETE", f"/api/v2/workflow_job_template_nodes/{n['id']}/")
have = {}


def node(identifier, jt=None, approval=None):
    if identifier in have:
        return have[identifier]
    body = {"identifier": identifier}
    if jt:
        body["unified_job_template"] = jt
    st, d = api("POST", f"/api/v2/workflow_job_templates/{wf}/workflow_nodes/", body)
    nid = d["id"]
    if approval:
        api("POST", f"/api/v2/workflow_job_template_nodes/{nid}/create_approval_template/",
            {"name": approval, "description": "Manual gate before Arkime DB init", "timeout": 0})
    have[identifier] = nid
    return nid


n_pre = node("01-preflight", jt=jt_ids["preflight"])
n_es = node("02-elasticsearch", jt=jt_ids["deploy_elasticsearch"])
n_appr = node("03-approval", approval=f"{PREFIX} approve Arkime init")
n_init = node("04-initialize", jt=jt_ids["initialize_arkime"])
n_rec = node("05-recorders", jt=jt_ids["deploy_recorders"])
n_ldap = node("05b-lab-ldap", jt=jt_ids["lab_ldap"])
n_ngx = node("06-nginx", jt=jt_ids["deploy_nginx"])
n_val = node("07-validate", jt=jt_ids["validate"])


def link(a, b):
    api("POST", f"/api/v2/workflow_job_template_nodes/{a}/success_nodes/", {"id": b})


link(n_pre, n_es)
link(n_es, n_appr)
link(n_appr, n_init)
link(n_init, n_rec)
link(n_rec, n_ldap)
link(n_ldap, n_ngx)
link(n_ngx, n_val)
created["workflow_nodes"] = {
    "preflight": n_pre, "elasticsearch": n_es, "approval": n_appr,
    "initialize": n_init, "recorders": n_rec, "lab_ldap": n_ldap,
    "nginx": n_ngx, "validate": n_val,
}

os.makedirs(ART, exist_ok=True)
with open(os.path.join(STATE, "awx_objects.json"), "w") as f:
    json.dump(created, f, indent=2)
with open(os.path.join(ART, "awx_objects.json"), "w") as f:
    json.dump(created, f, indent=2)
print("\nDONE. Objects:")
print(json.dumps(created, indent=2))
