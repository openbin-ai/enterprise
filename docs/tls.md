# TLS

Three modes, chosen at install time (`TLS_MODE` in `.env`). Change it
later with `bin/openbin-enterprise render && bin/openbin-enterprise up`.

## internal (default)

Caddy runs a private CA and issues certificates for the five hostnames
itself. No outside dependency, which is why it is the default for isolated
networks. Every client that talks to the instance must trust the root:

```sh
bin/openbin-enterprise ca-cert > openbin-root-ca.crt
```

- **Linux:** `sudo cp openbin-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`
  (Debian/Ubuntu) or `sudo cp ... /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust` (RHEL).
- **macOS:** `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain openbin-root-ca.crt`
- **Windows:** `certutil -addstore -f Root openbin-root-ca.crt` in an elevated prompt,
  or push it with Group Policy.
- **Firefox** keeps its own store unless `security.enterprise_roots.enabled` is true.
- **The `openbin` CLI** uses the operating system store, so the steps above cover it.
- **Docker on analyst machines** only pulls worker images over HTTPS from
  the instance via the CLI, which again uses the OS store.

The root certificate lives in the `openbin_caddy-data` volume. Back it up
with the rest (`backup.md` covers it) so a rebuilt host keeps the same CA.

## acme

Public certificates from Let's Encrypt. The host must be reachable from
the internet on ports 80 and 443 under all five hostnames, and
`ACME_EMAIL` must be set. Renewal is automatic.

## custom

Bring a certificate that covers `*.<domain>` (or all five names as SANs).
Place the full chain and key at `config/tls/fullchain.pem` and
`config/tls/privkey.pem` (the installer copies them there when given
`--cert`/`--key`). Renewals: replace the files and run
`bin/openbin-enterprise restart proxy`.

## Inside the stack

Containers never go through the proxy for each other. The backend fetches
signing keys from Keycloak over the internal network and validates tokens
against the public issuer name, so it does not need to trust the proxy's
certificate in any mode.
