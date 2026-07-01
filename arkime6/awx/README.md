# FPC AWX artifacts

Everything AWX needs to run the FPC Arkime build as code: the execution
environment (EE) definition, objects-as-code for the controller, and the gated
deployment workflow. **No secrets live in this directory or anywhere in Git** —
they are injected at run time by AWX credentials.

## Layout

| File | Purpose |
|---|---|
| `execution-environment.yml` | ansible-builder v3 definition for the EE image |
| `requirements.yml` | Galaxy collections baked into the EE (pins match `../requirements.yml`) |
| `requirements.txt` | Python deps for the EE |
| `bindep.txt` | System deps for the EE |
| `job_templates/objects.yml` | Playbook: org, project, inventory, groups, credentials, credential types, job templates |
| `workflow/workflow.yml` | Playbook: the 9-stage workflow with approval gates and a launch survey |

## 1. Build the execution environment

```bash
python -m pip install ansible-builder
ansible-builder build \
  -f awx/execution-environment.yml \
  -t fpc-ee:24.6.1 \
  --context ./.ee-context -v3
# Push to the registry AWX pulls from, then register it as an EE in the controller.
```

The EE bundles `ansible-core==2.21.1`, `ansible-runner`, the pinned collections,
and the Python/system deps. The Docker Compose v2 plugin is intentionally **not**
in the EE — Compose runs on the managed target hosts (installed by the
`docker_engine` role), invoked there over SSH by `community.docker.docker_compose_v2`.

## 2. Apply the controller objects

Both playbooks run on `localhost` and talk to the controller API. Provide the
controller connection at apply time (never commit it):

```bash
export CONTROLLER_PASSWORD='…'   # or use a controller token / AWX env
ansible-playbook awx/job_templates/objects.yml \
  -e fpc_controller_host=https://awx.example.com \
  -e fpc_controller_username=admin \
  -e fpc_scm_url=https://git.example.com/fpc/fpc_production_build_arikme.git

ansible-playbook awx/workflow/workflow.yml \
  -e fpc_controller_host=https://awx.example.com \
  -e fpc_controller_username=admin
```

`objects.yml` creates the organization, the SCM (git) project, the inventory with
the `elasticsearch_physical_hosts` and `arkime_recorders` groups, the machine
credential, the two custom credential types (LDAP bind, container registry), and
one job template per operational playbook. Every cluster-mutating template sets
`allow_simultaneous: false`.

`workflow.yml` wires the nine stages and inserts manual **approval** gates before
the three high-risk stages — `initialize_arkime`, `upgrade`, and `recover` — and
attaches a launch survey for `elasticsearch_nodes_per_host`, `arkime_image_digest`,
`es_image_digest`, and `confirm_destroy`.

## 3. How secrets are injected (never in Git)

Secrets are supplied exclusively through AWX credentials and surface in playbooks
as `vault_*` variables or environment variables:

| Secret | Delivery |
|---|---|
| SSH login to target hosts | **Machine** credential (`FPC SSH Machine`) |
| `ldap_bind_password` | **FPC LDAP Bind** custom credential type → env `FPC_LDAP_BIND_DN` / `FPC_LDAP_BIND_PASSWORD` |
| Registry login | **FPC Container Registry** custom credential type → env `FPC_REGISTRY_*` |
| `arkime_*`, `es_*`, CA passphrase, etc. | **Ansible Vault** credential (`FPC Ansible Vault`) decrypting the vaulted `vault_*` vars |

Attach the relevant credentials to each job template in the controller after
applying the objects. The objects/workflow playbooks reference credential **names
and variable names only** — never secret values.
