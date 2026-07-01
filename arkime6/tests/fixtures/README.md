# Test fixtures

Inputs the integration and verification tests consume. Binary blobs (PCAPs)
are intentionally **not** committed — supply them locally as described below.

## Sample PCAP

The Arkime capture/replay tests need a small packet capture. Binary `.pcap`
files are not shipped in this repo (keep the tree text-only and license-clean).

1. Obtain or create a small capture, e.g.:
   - `tcpdump -i <iface> -c 2000 -w sample.pcap` on a lab host, or
   - any public sample (e.g. a Wireshark sample capture).
2. Place it here as:

   ```text
   tests/fixtures/pcap/sample.pcap
   ```

3. The replay drill loads it into a recorder's capture path or replays it onto
   the capture interface, then asserts sessions land in Elasticsearch:

   ```bash
   # offline ingest (fastest, no NIC needed):
   docker exec fpc-arkime-capture \
     /opt/arkime/bin/capture -c /opt/arkime/etc/config.ini -r /tmp/sample.pcap
   # or replay onto the capture NIC from the lab control host:
   tcpreplay -i eth2 tests/fixtures/pcap/sample.pcap
   ```

`tests/fixtures/` is excluded from yamllint and ansible-lint, so a dropped-in
PCAP (and any local helper files) will not trip the linters.

## Seeded LDIF

`tests/fixtures/seed.ldif` seeds the lab OpenLDAP service (`ldap-test-01`,
`172.28.10.31:389`) with two users and the two Arkime groups. It matches the
lab `ldap_*` variables in `inventories/vagrant/group_vars/all.yml`:

| Item            | Value                                            |
|-----------------|--------------------------------------------------|
| Base DN         | `dc=lab,dc=local`                                |
| Bind (service)  | `cn=arkime-svc,ou=services,dc=lab,dc=local`      |
| User filter     | `(uid=%(username)s)`                             |
| Admin user      | `alice` — member of `arkime-admins`              |
| Regular user    | `bob` — member of `arkime-users`                 |
| Groups OU       | `ou=groups,dc=lab,dc=local`                      |

Load it:

```bash
ldapadd -x -H ldap://172.28.10.31:389 \
        -D "cn=admin,dc=lab,dc=local" -w "$LAB_LDAP_ADMIN_PW" \
        -f tests/fixtures/seed.ldif
```

The `userPassword` values are placeholders. Generate real SSHA hashes with
`slappasswd -s '<password>'` and substitute them before loading. Lab
credentials only — never reuse production secrets here.
