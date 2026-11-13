# Installation

There are two ways to lay the instance out on your network. Pick one at
install time; switching later means a fresh install.

| | By IP address (default) | By DNS names (`--domain`) |
|---|---|---|
| Users open | `https://<ip>/` and `https://<ip>:8443/` | `https://app.<domain>`, `https://apk.<domain>` |
| DNS records | none | five |
| Ports to allow | two, both configurable | 80 and 443 |
| Certificate | issued by the installer for the IP | internal CA, Let's Encrypt, or yours |

## Before you start

1. **A Linux host with Docker** Engine 24 or newer and the Compose v2
   plugin (`docker compose version`). That is the only software the host
   needs; the installer uses nothing else that a base system lacks.
2. **Sizing:** 8 vCPU, 16 GiB RAM, 100 GiB disk to begin with. See
   `sizing.md` before buying hardware for a team.
3. **Two free TCP ports** (IP layout), or **five DNS records** and ports
   80/443 (DNS layout).
4. **Registry access** only for online installs. The single-file installer
   and the offline bundle carry every image and need no network at all.

## Install by IP address

With the single-file installer:

```sh
sudo ./openbin-enterprise-<version>.run
```

That is the whole install. It verifies itself, unpacks to
`/opt/openbin-enterprise` (`--dest` to change), loads the images, detects
the host's address, generates every secret, issues a certificate, starts
the stack, and prints the two URLs and the first sign-in. It asks no
questions.

Options you may need:

```sh
sudo ./openbin-enterprise-<version>.run \
     --ip 10.0.4.17 \                 # if the detected address is not the one users type
     --openbin-port 8443 \            # default 443
     --openapk-port 8444 \            # default 8443
     --llm-allow 10.0.9.20            # model server on your network (host or CIDR, comma separated)
```

The two ports are the only ones the host exposes. The API, sign-in and
file storage are all served under them, so there is nothing else to open
in a firewall. If a port range is blocked on your network, choose any two
ports that are allowed.

From a tarball instead of the `.run` file, the same thing is
`./install.sh --images openbin-enterprise-images-<version>.tar.gz [options]`.

### First sign-in

The installer prints an email (`admin@openbin.local` unless you passed
`--admin-email`) and a one-time password. Open the OpenBin URL, accept the
certificate warning (or import the CA first, see `tls.md`), sign in, and
choose a new password when asked. That account is the platform
administrator.

Then:

1. Add a model under Settings > API keys. Inside an air gap that is the
   OpenAI-compatible provider pointed at a model server on your network;
   its host must have been allowed with `--llm-allow`.
2. Tell your team the URL. Sign-up is open by default in this layout:
   each person clicks "Register" on the sign-in page and creates their own
   account. To use LDAP or Active Directory instead, it is one command
   (`bin/openbin-enterprise ldap connect --help`, or the `--ldap-*`
   installer options); to close sign-up, `./install.sh --no-self-registration`.
   `sso.md` covers all of it.

Nobody needs the CLI: binaries and APKs are dropped straight onto the
Projects page and decompiled on the server. The CLI at
`https://<ip>/downloads/` is there for people who prefer a terminal.

### Changing the address or ports later

Re-run the installer with the new values. Secrets, accounts and data are
kept; the certificate is re-issued from the same CA and the sign-in
client is updated to the new URLs.

```sh
cd /opt/openbin-enterprise
./install.sh --ip 10.0.5.40
./install.sh --openbin-port 9443 --openapk-port 9444
```

## Install by DNS names

Create five A records pointing at the host (`app.`, `apk.`, `api.`,
`auth.`, `s3.` under your base domain), decide on TLS (`tls.md`), then:

```sh
./install.sh --domain re.corp.example --admin-email you@corp.example
```

Add `--images FILE` for the offline bundle, or
`--registry-token TOKEN` to pull from `ghcr.io/openbin-ai/enterprise`.
`./install.sh --help` lists everything.

First sign-in in this layout:

1. Open `https://auth.<domain>/admin/` and sign in with the user `admin`
   and the `KEYCLOAK_ADMIN_PASSWORD` from `.env`. Keycloak treats this
   bootstrap account as temporary: create a permanent administrator in the
   master realm now.
2. In the `openapk` realm, create user accounts for your analysts (Users >
   Add user, set a password under Credentials), or connect your identity
   provider as described in `sso.md`.
3. Open `https://app.<domain>` and sign in with the administrator email you
   gave the installer. That address is also allowlisted for the platform's
   admin API.
4. Add a model provider under Settings > API keys. If the endpoint is on a
   private network, list its hostname or CIDR in `LLM_EGRESS_ALLOWLIST`
   (`--llm-allow`) first; the backend refuses private destinations otherwise.

## What the installer does

- generates every secret (database passwords, the key that encrypts stored
  API keys, MinIO credentials, the worker token) into `.env` with mode 600,
- loads or pulls images,
- renders `config/Caddyfile` and the Keycloak realm from `.env`,
- starts the stack and waits for the backend's health check (first boot
  runs database migrations and takes a minute or two),
- prints the URLs and next steps (`bin/openbin-enterprise urls` prints
  them again).

Re-running `./install.sh` with an existing `.env` keeps your secrets.
`--force` regenerates them, which makes stored API keys unreadable, so
only use it on a fresh install.

Always drive the stack through `bin/openbin-enterprise` (for raw compose
commands: `bin/openbin-enterprise compose ...`). The public URLs are
derived from `.env` by that wrapper, so a bare `docker compose` in the
install directory does not see them.

## Where things live

| Path | Contents |
|---|---|
| `.env` | all configuration and secrets |
| `config/Caddyfile`, `config/keycloak/import/` | rendered from `.env`; do not hand-edit |
| `config/tls/` | your certificate in custom mode; this install's CA and certificate in the IP layout (back it up) |
| `downloads/` | CLI, worker images, BINNY, install scripts served at `/downloads/` |
| Docker volumes `openbin_postgres-data`, `openbin_minio-data`, `openbin_caddy-data`, `openbin_core-workspace` | data |

## Uninstall

```sh
bin/openbin-enterprise down
docker volume rm openbin_postgres-data openbin_minio-data openbin_caddy-data openbin_caddy-config openbin_core-workspace
```
