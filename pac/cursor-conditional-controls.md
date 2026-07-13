# SMD — Cursor: conditional-approval requirements (only via TPRM + risk acceptance)

Default position: **defer** (Section 3.3 of the controls package). Cursor cannot
satisfy "SMD-hosted LLMs only": per Cursor's own documentation, customer API keys
are sent to Cursor's servers with every request and all requests route through
Cursor's backend for final prompt construction; key-based routing covers
chat/plan only (OpenAI-compatible APIs); Agent/Composer, inline edit, and Tab
are locked to Cursor-hosted models; codebase indexing stores embeddings of SMD
code on Cursor infrastructure; Vertex AI is not a supported provider (open
feature request). If the business case forces earlier adoption, ALL of the
following are mandatory conditions, and the approval is a named exception with
documented risk acceptance of the backend-transit exposure — not a precedent.

## A. Commercial / TPRM gate (before any install)

1. Business/Enterprise agreement with DPA; Anysphere added to the processor
   register for source code.
2. Evidence pack: current SOC 2 Type II report; subprocessor list (model
   providers, embedding store); data-flow and retention statement for
   (a) prompt/context transit, (b) codebase-index embeddings, (c) support access.
3. Written confirmation of Privacy Mode zero-data-retention terms with model
   providers, and that Privacy Mode is org-enforceable (not user-optional).
4. CVE posture review: Cursor had seven CVEs in 2025 including an RCE via MCP
   prompt injection ("CurXecute"); require the vendor's SLA for security fixes
   and confirm our version pinning + advisory subscription (CC-13) covers Cursor.
5. Re-test the Vertex question at review time: if Cursor has shipped true
   direct-to-endpoint routing for ALL features, escalate for re-assessment
   under the standard onboarding criteria instead of this exception path.

## B. Admin-enforced tenant configuration

- Privacy Mode: enforced ON for every seat at the team level (verify a member
  cannot toggle it off).
- SSO enforced; SCIM provisioning; seats limited to the approved SMD IQ cohort.
- Model allowlist restricted to providers named in the DPA. No BYOK by
  individual developers (keys imply per-dev provider relationships and still
  transit Cursor's backend — worst of both).
- Any tenant-level MCP/agent/auto-run admin toggles: most restrictive setting.

## C. Workstation baseline (deployed with the app, not left to users)

- `.cursorignore` and `.cursorindexingignore` seeded org-wide (template below)
  — and treated as a **context filter, not a security control**: Cursor
  documents ignore handling for chat as best-effort, and recently viewed files
  can still enter requests. The real control is CC-05: no secrets in repos.
- Codebase indexing: disabled for repositories classified Confidential-High
  until the embedding-storage review (A.2) concludes; where enabled, verify
  gitignored paths are excluded by default.
- Agent auto-run / "YOLO" style execution: disabled; terminal and file-write
  actions require confirmation (CC-04).
- MCP: disabled, or restricted to the CC-07 allowlist with the same review
  workflow as Claude Code servers. No credentials inside `mcp.json` — use
  environment references.
- Workspace trust and extension governance: mirror the VS Code baseline where
  Cursor exposes equivalent settings; extensions limited to the approved list.
- Updates: pinned versions via internal distribution; no in-app self-update
  outside the ring process (CVE history makes patch latency a real risk — the
  ring must be fast).

### .cursorignore starter (also copy to .cursorindexingignore)

```
.env
.env.*
*.pem
*.key
*.p12
*.pfx
id_rsa*
id_ed25519*
secrets/
**/secrets/**
.aws/
.config/gcloud/
.kube/
.npmrc
.netrc
terraform.tfstate*
**/customer-data/**
```

## D. Network + monitoring

- Egress: allow only Cursor's documented service domains for licensed seats
  (enumerate from vendor docs at deployment; see egress-allowlist.md) — and
  keep model-provider APIs blocked from developer VLANs so unmanaged BYOK
  fails closed.
- Proxy logs for Cursor domains flow to SIEM; alert on Cursor traffic from
  non-licensed hosts (shadow install detection).
- No Cursor on machines holding regulated or Confidential-High data until the
  A.2 review concludes.

## E. Exit criteria for the exception

The exception is re-reviewed at Gateway GA and at every Cursor architecture
change. It lapses automatically if: the DPA/SOC 2 evidence expires, Privacy
Mode enforcement regresses, or an unpatched critical CVE exceeds the agreed SLA.
