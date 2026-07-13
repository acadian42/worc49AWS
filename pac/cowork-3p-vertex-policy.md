# SMD — Claude Cowork on Vertex AI (third-party deployment): MDM policy checklist

Status: Phase 2 (after Claude Code pilot exit). Cowork's third-party (3P)
deployment mode, published by Anthropic in April 2026, routes inference from
the workstation directly to a configured Vertex AI endpoint and moves all
governance to MDM. Before deploying, pull the **current** MDM key reference —
key names below were verified against the April 2026 articles and can change:

- Install and configure Claude Cowork with third-party platforms — support.claude.com article 14680741
- Extend Claude Cowork with third-party platforms (MCP, plugins, tools) — support.claude.com article 14680753
- Deploy Cowork on 3P with Google Cloud's Vertex AI — claude.com/docs/cowork/3p/vertex
- Enterprise configuration for Claude Desktop (MDM domains/paths) — support.claude.com article 12622667

Delivery: export from the setup tooling as `.mobileconfig` (macOS, domain
`com.anthropic.claudefordesktop`, via Jamf/Kandji/Intune) or `.reg` (Windows,
HKLM preferred over HKCU; Intune/GPO). Windows prerequisite: the
"Virtual Machine Platform" feature must be enabled (Cowork's task execution is
VM-isolated on Windows).

## 1. Inference routing — SMD Vertex only (CC-02)

| Key | Required value | Notes |
|---|---|---|
| `inferenceProvider` | `vertex` | Locks inference to the 3P Vertex path; no consumer/api.anthropic.com fallback. |
| project / region keys | SMD AI Vertex project + pinned region | Exact key names per current reference table. |
| `inferenceModels` | Explicit allowlist of Vertex publisher model IDs (e.g., `claude-sonnet-4-6@...`) | Required in 3P mode; acts as the model allowlist. Pin versions, no aliases. |
| Credential source (exactly one) | Prefer **Workforce Identity Federation** (per-user attribution in Cloud Audit Logs, no Google identities needed for Entra/Okta users). Alternatives: `inferenceVertexCredentialsFile` (service-account key at a fixed MDM-managed path — weakest attribution; protect the file), in-app Google sign-in (OAuth client), or `inferenceCredentialHelper`. | Per-user identity is what makes CC-10 auditing work; avoid a shared service account for the pilot. |

## 2. Tool and extension lockdown (CC-04 / CC-07 / CC-08)

| Key | Required value | Rationale |
|---|---|---|
| `isLocalDevMcpEnabled` | `false` | Users cannot add their own MCP servers; only the managed list loads. |
| `managedMcpServers` | JSON array of approved remote servers (unique name + HTTPS URL; optional headers/OAuth/tool policies) | Default-deny MCP; entries go through the Section 6 intake and code review. No credentials in-line. |
| `isDesktopExtensionEnabled` | `true` only if needed | If enabled, pair with the two keys below. |
| `isDesktopExtensionDirectoryEnabled` | `false` | Hides the public Anthropic extension directory. |
| `isDesktopExtensionSignatureRequired` | `true` | Only signed, vetted extensions install. |
| `disabledBuiltinTools` | Start with `["WebSearch", "Bash"]` for the initial cohort | Cuts the R1 injection surface and R2 execution surface; relax deliberately per role after review. Built-ins include Task, Bash, Glob, Grep, Read, Edit, Write, WebFetch, WebSearch, etc. |
| Plugins | Distribute via the MDM-mounted `org-plugins` directory only | No public marketplace in 3P mode; mount-distributed plugins are available to all users on the machine — combine with signature requirement above. |
| Telemetry-to-Anthropic keys | Disabled per current MDM reference (CC-03) | 3P mode supports disabling non-essential telemetry uploads; verify key names. |
| Token caps / usage windows | Set per current reference | Cost containment during pilot. |

## 3. Observability (CC-09 / CC-10)

- Enable Cowork's OpenTelemetry export to the same SMD collector used for
  Claude Code (Cowork emits the same event family: api_request, tool_result,
  permission decisions, with user/session identifiers). See Elastic Security
  Labs' Claude Code/Cowork OTel pipeline write-up for a working schema.
- Cowork activity is **not** in Anthropic's enterprise audit logs / Compliance
  API — in 3P mode your audit trail is: OTel events + Vertex Cloud Audit Logs
  (per-user via WIF) + MDM inventory + egress proxy logs. Stand these up
  before the first user.

## 4. Pilot guardrails

- Cohort: SMD IQ platform team members only; corporate-managed devices only.
- Same Vertex project, budgets, and quotas as the Claude Code pilot.
- Success criteria mirror Phase 1 (README test plan) plus: no unmanaged MCP
  server observed in telemetry; extension installs only from org directory.
