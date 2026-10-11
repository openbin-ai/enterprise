# Installation

## Before you start

1. **A Linux host** with Docker Engine 24 or newer and the Compose v2
   plugin (`docker compose version`). Rootless Docker works but needs
   `HTTP_PORT`/`HTTPS_PORT` above 1024 and a port forward.
2. **Sizing:** 8 vCPU, 16 GiB RAM, 100 GiB disk to begin with. See
   `sizing.md` before buying hardware for a team.
3. **DNS:** five A records pointing at the host:
   `app.<domain>`, `apk.<domain>`, `api.<domain>`, `auth.<domain>`,
   `s3.<domain>`. In a lab, `/etc/hosts` entries on each analyst machine
   also work.
4. **TLS decision** (see `tls.md`): internal CA (default), Let's Encrypt,
   or your own wildcard certificate for `*.<domain>`.
5. **Registry access** for online installs: the token we issued you for
   `ghcr.io/openbin-ai/enterprise`. Offline installs use the image bundle
   instead and need no network at all.

## Run the installer

```sh
tar xzf openbin-enterprise-<version>.tar.gz
cd openbin-enterprise-<version>
./install.sh
```

Interactive prompts ask for the base domain, the administrator email and
the TLS mode. Everything can be given as flags for unattended installs;
`./install.sh --help` lists them. The installer:

- refuses to continue if ports 80 or 443 are taken,
- generates every secret (database passwords, the key that encrypts stored
  API keys, MinIO credentials, the worker token) into `.env` with mode 600,
- renders `config/Caddyfile` and the Keycloak realm from `.env`,
- pulls or loads images, starts the stack, and waits for the backend's
  health check (first boot runs database migrations and takes a minute or
  two),
- prints the URLs, the Keycloak admin password location and next steps.

Re-running `./install.sh` with an existing `.env` keeps your secrets and
only re-renders and restarts. `--force` regenerates secrets, which makes
stored API keys unreadable, so only use it on a fresh install.

## First sign-in

1. Open `https://auth.<domain>/admin/` and sign in with the user `admin`
   and the `KEYCLOAK_ADMIN_PASSWORD` from `.env`. Keycloak treats this
   bootstrap account as temporary: create a permanent administrator in the
   master realm now.
2. In the `openapk` realm, create user accounts for your analysts (Users >
   Add user, set a password under Credentials), or connect your identity
   provider as described in `sso.md`. Self-registration is off by default;
   `SELF_REGISTRATION=true` in `.env` plus `bin/openbin-enterprise render`
   and `up` turns it on.
3. Open `https://app.<domain>` and sign in with the administrator email you
   gave the installer. That address is also allowlisted for the platform's
   admin API.
4. Add a model provider under Settings > API keys. Anthropic, OpenAI,
   OpenAI-compatible gateways and Bedrock are supported. If the endpoint is
   on a private network, list its hostname or CIDR in `LLM_EGRESS_ALLOWLIST`
   in `.env` first; the backend refuses private destinations otherwise.

## Where things live

| Path | Contents |
|---|---|
| `.env` | all configuration and secrets |
| `config/Caddyfile`, `config/keycloak/import/` | rendered from `.env`; do not hand-edit |
| `config/tls/` | your certificate in custom mode |
| `downloads/` | CLI, worker images, BINNY, install scripts served at `/downloads/` |
| Docker volumes `openbin_postgres-data`, `openbin_minio-data`, `openbin_caddy-data`, `openbin_core-workspace` | data |

## Uninstall

```sh
bin/openbin-enterprise down
docker volume rm openbin_postgres-data openbin_minio-data openbin_caddy-data openbin_caddy-config openbin_core-workspace
```
