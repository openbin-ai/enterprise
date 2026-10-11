# OpenBin Enterprise

Self-hosted OpenBin and OpenAPK for private networks: one host, one
`install.sh`, everything in Docker Compose. Built for environments that
cannot use the hosted service, including air-gapped ones.

This repository is private. The platform itself is open source under
AGPL-3.0 at github.com/openbin-ai/platform; what lives here is the
supported distribution: the installer, the composed stack, the images, the
offline bundle, and the operating docs. Customers receive it under a
commercial license that replaces the AGPL terms for their use.

## What you get

| Component | Role |
|---|---|
| `proxy` (Caddy) | TLS and routing for the five hostnames |
| `frontend` | OpenBin and OpenAPK web apps, plus `/downloads/` for the CLI and BINNY |
| `core` | Spring Boot backend |
| `postgres` | platform and Keycloak databases |
| `keycloak` | sign-in, users, SSO brokering |
| `minio` | object storage for samples, media and analysis results |
| `ghidra-worker`, `jadx-worker` | in-cluster decompilers (web uploads work without the CLI) |
| `script-worker`, `pypi-worker`, `shell-worker` | npm, PyPI and shell analyzers |

Hostnames, all on one base domain: `app.`, `apk.`, `api.`, `auth.`, `s3.`.

## Install

Requirements: Linux host, Docker Engine 24+ with Compose v2, 8 vCPU,
16 GiB RAM, 100 GiB disk, DNS for the five hostnames. Details in
[docs/sizing.md](docs/sizing.md).

```sh
tar xzf openbin-enterprise-<version>.tar.gz && cd openbin-enterprise-<version>
./install.sh --domain re.corp.example --admin-email you@corp.example --registry-token <token>
```

Air-gapped, with the offline bundle:

```sh
./install.sh --domain re.corp.example --admin-email you@corp.example \
             --images openbin-enterprise-images-<version>.tar.gz
```

The installer writes `.env`, renders the proxy and realm configuration,
loads or pulls images, starts the stack and prints the URLs. Full
walkthrough in [docs/install.md](docs/install.md).

## Operate

```
bin/openbin-enterprise status | logs [service] | backup | restore DIR | upgrade | ca-cert
```

- [docs/tls.md](docs/tls.md): internal CA, Let's Encrypt, or your own certificate
- [docs/sso.md](docs/sso.md): connecting SAML, OIDC or LDAP through Keycloak
- [docs/cli.md](docs/cli.md): analyst setup, `openbin login --server`
- [docs/backup.md](docs/backup.md), [docs/upgrade.md](docs/upgrade.md), [docs/air-gap.md](docs/air-gap.md)
- [docs/architecture.md](docs/architecture.md): how the pieces connect and what differs from the hosted service

## Build a release (maintainers)

```sh
scripts/build-images.sh --platform-dir ../OpenAPK          # images from the platform checkout
scripts/push-images.sh                                     # to ghcr.io/openbin-ai/enterprise
scripts/fetch-downloads.sh --platform-dir ../OpenAPK       # CLI, worker tarballs, BINNY, install scripts
scripts/save-images.sh                                     # one tar.gz with every image
scripts/package.sh            # online bundle
scripts/package.sh --offline  # bundle with images + downloads
```

Bump `VERSION` first. The platform changes that make this distribution
possible (runtime frontend config, HTTP script workers, public S3
endpoint, `/api/public/config`, `openbin login --server`) are in the public
repository, so a release here is always built from a platform commit that
includes them.
