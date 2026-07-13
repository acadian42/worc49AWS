# SMD — Developer VLAN egress policy for AI coding tools (CC-02 / CC-03 / CC-11)

Principle: developer VLANs deny direct model-API egress by default, so any
unmanaged tool or BYOK attempt fails closed. Only the flows below are opened,
logged at the proxy, and forwarded to SIEM. Endpoints marked (verify) must be
confirmed against vendor documentation and observed traffic during Phase 0 —
vendors add/rename endpoints without notice; re-validate quarterly (CC-14).

## ALLOW — Claude Code and Cowork (3P) on Vertex

| Destination | Purpose | Notes |
|---|---|---|
| `<REGION>-aiplatform.googleapis.com` | Vertex inference (regional) | One entry per pinned region. |
| `aiplatform.googleapis.com` | Vertex inference (global endpoint) | Only if CLOUD_ML_REGION=global is used. |
| `oauth2.googleapis.com`, `accounts.google.com` | Google auth token flows (ADC / sign-in) | |
| `sts.googleapis.com`, `iamcredentials.googleapis.com` | Workforce Identity Federation / SA impersonation | Only if WIF or impersonation is used. (verify) |
| `<otel-collector>.smd.internal:4317` | OpenTelemetry export (CC-09) | Internal; mTLS on collector. |

## ALLOW — VS Code product flows

| Destination | Purpose | Notes |
|---|---|---|
| `update.code.visualstudio.com` | Update checks | Only if UpdateMode permits checks; binaries ship via internal distribution regardless. (verify CDN hostnames from the VS Code network hostname list) |
| `marketplace.visualstudio.com`, `*.gallery.vsassets.io` | Extension metadata/downloads | Constrained by AllowedExtensions policy; replace entirely with private-marketplace host if adopted. (verify) |

## ALLOW — Cursor (ONLY if the conditional exception is approved; per licensed host)

| Destination | Purpose | Notes |
|---|---|---|
| Cursor service domains, e.g. `api2.cursor.sh` and related | Chat/agent backend, auth, indexing | (verify — enumerate the current official list from Cursor docs/support at deployment; do not open wildcards) |

## DENY (explicit, logged, alerting)

| Destination | Reason |
|---|---|
| `api.anthropic.com` | Inference must go via SMD Vertex (CC-02). Revisit only for an approved Claude Enterprise SaaS decision. |
| `api.openai.com`, `generativelanguage.googleapis.com`, other public model APIs | Blocks unmanaged BYOK/shadow AI from developer VLANs. |
| `statsig.anthropic.com`, `*.statsig.com`, `*.sentry.io` | Vendor operational telemetry (CC-03) — belt-and-braces on top of env flags. (verify exact hosts from observed traffic) |
| Cursor service domains | On all hosts EXCEPT licensed exception seats — shadow-install detection. |

## SIEM hooks

- Proxy log fields: host, SNI, bytes out, user/device, verdict.
- Alerts: (1) denied model-API attempts by host/user; (2) Cursor domains from
  non-licensed hosts; (3) statsig/sentry attempts after rollout (indicates a
  machine missing the managed policy); (4) Vertex traffic from devices without
  MDM compliance.
