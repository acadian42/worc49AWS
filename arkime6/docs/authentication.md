# Authentication

The platform uses **Arkime 6 hybrid `authMode = header+digest`**: Nginx +
LDAP/AD is the primary path (header auth), with HTTP digest kept as a local
emergency fallback. Nginx is the only public entrypoint; the Arkime viewer binds
to `127.0.0.1` only.

## Request flow (header auth, the normal path)

```text
Analyst --HTTPS 443--> Nginx --auth_request--> ldap-auth sidecar --LDAPS--> AD
                         |  (on 401/403: deny; on outage: deny = fail-closed)
                         v  (on 200)
                       Nginx sets remote-user / remote-groups headers
                         |
                         v
                       Arkime viewer (127.0.0.1:8005) trusts the headers
                       because the CONNECTING IP is loopback (userAuthIps)
```

## Arkime settings (config.ini, from the variable contract)

| Setting (Arkime)        | Variable                       | Value / meaning                                   |
|-------------------------|--------------------------------|---------------------------------------------------|
| `authMode`              | `arkime_auth_mode`             | `header+digest` — header primary, digest fallback |
| `userNameHeader`        | `arkime_username_header`       | `remote-user` — header Nginx sets after LDAP OK   |
| `requiredAuthHeader`    | `arkime_required_auth_header`  | `remote-groups` — group header that must match    |
| `requiredAuthHeaderVal` | `arkime_user_ldap_groups`      | CSV of allowed groups (`arkime-admins,arkime-users`) |
| `userAuthIps`           | `arkime_user_auth_ips`         | `127.0.0.1/32` — only trust headers from loopback |

* **`requiredAuthHeader` + `requiredAuthHeaderVal`** gate both access and
  auto-creation: a user is admitted/created only if `remote-groups` contains one
  of the allowed values. Users are not auto-deleted when the headers later go
  missing.
* **`userAuthIps` and the proxy-IP check.** All `header*` modes default
  `userAuthIps` to localhost-only (since 6.4.0). In **6.5.0 the check is against
  the connecting / proxy IP** — i.e. the socket peer that hands Arkime the
  request, which here is Nginx on loopback. Because the viewer listens only on
  `127.0.0.1` and only Nginx connects to it, an attacker cannot reach the viewer
  directly to spoof `remote-user`. Keep `userAuthIps = 127.0.0.1/32`.

### `[user-auto-create]`

With `arkime_auto_create_users: true`, the first successful header login
provisions the Arkime user from the header values, assigning
`arkime_default_role` (`arkimeUser`, least privilege). Membership of
`arkime_admin_ldap_group` maps to admin. New users land least-privileged by
default; elevation is explicit.

## Nginx hardening: `auth_request` + header stripping

The Nginx config (`nginx_ldap_proxy` role) enforces:

* **`auth_request`** to the ldap-auth sidecar on every protected location; a
  non-200 subrequest denies the request before it ever reaches the viewer.
* **Header stripping (critical).** Nginx **unsets any client-supplied**
  `remote-user` / `remote-groups` (and related auth) headers on the inbound
  request, then sets them **only** from the authenticated subrequest response
  (`auth_request_set` -> `proxy_set_header`). This prevents an analyst from
  smuggling their own identity/group headers to forge admin access.
* **TLS + HSTS** (`nginx_hsts_enabled`), HTTP→HTTPS redirect
  (`nginx_redirect_http`), large-body allowance for PCAP downloads
  (`nginx_client_max_body_size: 0`), and long read timeouts
  (`nginx_proxy_read_timeout`).

## AD / LDAPS via the caltechads sidecar

The `caltechads/nginx-ldap-auth-service` container is the `auth_request`
backend. It binds to AD over **LDAPS (636)** using:

| Variable                  | Purpose                                      |
|---------------------------|----------------------------------------------|
| `ldap_url`                | `ldaps://ad.example.com:636`                 |
| `ldap_bind_dn` / `ldap_bind_password` | service account (secret, `no_log`)|
| `ldap_base_dn`            | search base                                  |
| `ldap_user_filter`        | `(sAMAccountName=%(username)s)`              |
| `ldap_group_attribute`    | `memberOf` — drives the `remote-groups` header |
| `ldap_ca_file`            | CA that signs the AD LDAPS cert              |
| `ldap_starttls`           | `false` (using LDAPS, not StartTLS on 389)   |

On success the sidecar returns 200 plus the user/group attributes Nginx maps
into the trusted headers; on bad credentials or group-mismatch it returns 401/403.

## Local emergency (digest) login + audit

* `authMode = header+digest` keeps **HTTP digest** available for a break-glass
  local admin (`arkime_admin_user` / `arkime_admin_password`, both `no_log`) when
  AD is unavailable or Nginx is bypassed for on-host troubleshooting.
* The digest `ha1` hash depends on `arkime_http_realm` (`Moloch`) — changing the
  realm invalidates stored digest hashes.
* **Workflow:** use only from the host/loopback, perform the action, then
  **rotate `arkime_admin_password`** (re-run the recorder role) afterward.
* **Audit:** emergency logins are a notable event — record who/when/why,
  monitor the viewer auth logs, and treat any digest login from a non-loopback
  source as an incident.

## Fail-closed behavior on LDAP outage

* If AD/LDAPS is unreachable, the `auth_request` subrequest does **not** return
  200, so **Nginx denies the request** — the platform fails *closed*, never open.
* Header auth cannot be satisfied without a real authenticated subrequest
  (clients can't supply the trusted headers — they are stripped and re-set only
  from the subrequest), so an LDAP outage cannot be exploited to gain access.
* The only path that still works during an outage is the local digest
  break-glass account from loopback, which is audited and rotated as above.
