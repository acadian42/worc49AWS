# SMD AI coding tools — template deployment guide

Companion to *SMD-AI-Coding-Tools-Compensating-Controls.docx*. Each template
maps to control IDs (CC-xx) defined in Section 4 of that document.

| File | Controls | Deploy to |
|---|---|---|
| `claude-code-managed-settings.json` | CC-01/02/03/04/05/06/07/09 | macOS: `/Library/Application Support/ClaudeCode/managed-settings.json` · Linux/WSL: `/etc/claude-code/managed-settings.json` · Windows: `C:\ProgramData\ClaudeCode\managed-settings.json` |
| `claude-code-vertex-pilot.env` | CC-02/03/09 | Build agents / containers only; workstations rely on managed settings |
| `cowork-3p-vertex-policy.md` | CC-01/02/03/04/07/08/09 | Values exported as `.mobileconfig` / `.reg` via Jamf/Intune/GPO (Phase 2) |
| `vscode-policy-baseline.json` | CC-03/08/13 | Windows: GPO/Intune registry `HKLM\SOFTWARE\Policies\Microsoft\VSCode` (ADMX in each release's `policies/` dir) · macOS: configuration profile · Linux: `/etc/vscode` policy file |
| `cursor-conditional-controls.md` | Exception path only | TPRM package + tenant admin + workstation baseline |
| `egress-allowlist.md` | CC-02/03/11 | Proxy/firewall for SMD IQ developer VLAN |

## Managed-file hardening (CC-01)

Managed settings are only as strong as their file permissions. Deploy via MDM
with: owner `root`/`SYSTEM`, mode `0644` (no group/other write), parent
directory not user-writable. Where supported, add an immutability layer
(macOS `sudo chflags schg <file>`; Linux `sudo chattr +i <file>`) and have MDM
compliance re-assert file hash daily. Developers must not have local admin
(CC-12) or the managed layer can be edited around.

## Placeholders to fill before deployment

- `REPLACE-smd-ai-vertex-project` — the SMD AI Vertex project ID.
- `REPLACE-region-...` — pinned Vertex region (or `global`); one egress entry per region.
- `REPLACE-pinned-vertex-model-id` — explicit model version from Model Garden
  (never an alias; aliases break when a version isn't enabled in the project).
- `REPLACE-otel-collector...` — the OTLP collector endpoint (mTLS recommended).
- VS Code `AllowedExtensions` — confirm the Claude Code extension's exact
  marketplace ID and finalize the developer extension set (allowlist-as-code:
  keep the source list in a reviewed repo and generate per-OS payloads).

## Enforcement verification test plan (run at Phase 1 start, then monthly)

1. **Routing**: launch `claude`; status line shows the Vertex project/region.
   From the same host, `curl https://api.anthropic.com` is denied at the proxy
   and the denial appears in SIEM.
2. **Deny rules**: ask the agent to read `.env` → permission denied error.
   Ask it to run `curl example.com` → denied. `/permissions` shows the rules
   sourced from managed settings and non-editable.
3. **Bypass mode**: `claude --dangerously-skip-permissions -p "echo test"` →
   must be rejected. If it is NOT rejected (see GitHub issue
   anthropics/claude-code#44642 for a prior report), file with the vendor,
   and rely on the compensating layer until fixed: managed deny `Bash(claude:*)`
   + EDR detection on the flag + no local admin.
4. **Settings precedence**: as a normal user, add an allow rule for
   `Bash(curl:*)` in `~/.claude/settings.json` → the managed deny still wins.
5. **Vendor telemetry**: after a working session, proxy logs show zero
   statsig/sentry attempts (env flags working) — or blocked attempts only
   (flags missing on that host: fix the MDM push).
6. **OTel**: collector receives `user_prompt`, `tool_result` (with decision
   source), and `api_request` events attributed to the test user; the
   bypass-attempt and denied-permission detections fire on tests 2–3.
7. **Cloud audit**: Vertex Cloud Audit Logs (Data Access enabled on
   `aiplatform.googleapis.com`) attribute test calls to the individual
   developer identity, not a shared account.
8. **VS Code**: attempt to install a non-allowlisted extension → blocked with
   the "managed by your organization" notice; `telemetry.telemetryLevel`
   shows locked to policy value.
9. **MCP**: drop a `.mcp.json` into a test repo → server does not auto-load
   (`enableAllProjectMcpServers=false`); unapproved-MCP detection fires if
   configured.

## Privacy note on CC-09 telemetry

Default OTel export records prompt/response **lengths** and tool/permission
metadata — not content. OAuth-authenticated sessions include `user.email` in
attributes. Turning on content flags (`OTEL_LOG_USER_PROMPTS`,
`OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_TOOL_CONTENT`, `OTEL_LOG_RAW_API_BODIES`)
captures increasingly sensitive material (up to full conversation payloads):
treat as a joint InfoSec/Privacy/Works-council decision, restrict index access,
and set short retention. Start the pilot with defaults.
