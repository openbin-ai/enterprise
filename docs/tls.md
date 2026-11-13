# TLS

The mode is chosen at install time (`TLS_MODE` in `.env`). Installs
reached by IP address use `selfsigned` (or `custom`); installs with DNS
names use `internal`, `acme` or `custom`.

## selfsigned (IP layout default)

Browsers only allow sign-in over HTTPS, and no public authority issues
certificates for private IP addresses, so the installer creates its own
CA and a certificate for the host's address in `config/tls/`.

Without further steps, each analyst sees a certificate warning the first
time they open each of the two URLs, and clicks through it. To remove the
warning, import the CA using the per-OS steps under "internal" below. It
is served by the instance and printed by the CLI:

```sh
curl -kO https://<ip>/downloads/openbin-ca.crt
bin/openbin-enterprise ca-cert > openbin-root-ca.crt     # same file, on the host
```

The `openbin` CLI and `curl` have no click-through, so analyst machines
that use the CLI need the CA imported.

The CA is created once and lasts ten years. The server certificate lasts
825 days; running `./install.sh` (or `bin/openbin-enterprise up`) within
30 days of expiry, or after an address change, re-issues it from the same
CA, so an imported CA keeps working. `--san` adds further IPs or names to
the certificate. Keep `config/tls/` with your backups: `backup` copies it.

To use a certificate from your own authority instead, pass
`--cert fullchain.pem --key privkey.pem` to the installer.

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
