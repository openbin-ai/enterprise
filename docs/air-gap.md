# Air-gapped installation

Nothing in the stack needs internet access at runtime. Model providers are
the exception by nature: point BYOK keys at an internal gateway (see
`LLM_EGRESS_ALLOWLIST` in `install.md`) or at a provider reachable through
your egress proxy.

## On a connected machine

Build or receive the offline bundle, `openbin-enterprise-<version>-offline.tar.gz`.
It contains the installer, the compose stack, every container image as one
`docker save` archive, and `downloads/` with the CLI for all platforms, the
worker image tarballs the CLI loads for local decompiles, BINNY, and the
install scripts. Verify it:

```sh
sha256sum -c openbin-enterprise-<version>-offline.tar.gz.sha256
```

## On the isolated host

```sh
tar xzf openbin-enterprise-<version>-offline.tar.gz
cd openbin-enterprise-<version>
./install.sh --domain re.corp.example --admin-email you@corp.example \
             --images openbin-enterprise-images-<version>.tar.gz
```

`--images` loads the archive into Docker instead of pulling. TLS defaults
to the internal CA, which is what you want without public DNS. Distribute
the root certificate from `bin/openbin-enterprise ca-cert` to analyst
machines (`tls.md`).

## Analyst machines inside the air gap

Everything they need is served by the instance at
`https://app.<domain>/downloads/`:

```sh
curl -fsSL https://app.re.corp.example/downloads/install.sh | sh
openbin login --server https://api.re.corp.example
```

The install script served by the instance is rewritten to fetch from the
instance, and `--server` records where worker image tarballs come from, so
`openbin decompile` works with no path to the internet. Docker on the
analyst machine is still required for local decompiles; web uploads go
through the in-cluster workers and need nothing on the analyst side.

## Upgrades

Receive the next offline bundle, then:

```sh
bin/openbin-enterprise upgrade --images openbin-enterprise-images-<new>.tar.gz
```

See `upgrade.md`.
