# Air-gapped installation

Nothing in the stack needs internet access at runtime. Model providers are
the exception by nature: point BYOK keys at an internal gateway (see
`LLM_EGRESS_ALLOWLIST` in `install.md`) or at a provider reachable through
your egress proxy.

## The short version

Copy one file to the isolated host and run it:

```sh
sha256sum -c openbin-enterprise-<version>.run.sha256
sudo ./openbin-enterprise-<version>.run
```

The host needs Docker and nothing else: no DNS, no registry, no packages.
The installer prints `https://<ip>/` (OpenBin) and `https://<ip>:8443/`
(OpenAPK); `--openbin-port` and `--openapk-port` move them to ports your
network allows. `install.md` has the details. The rest of this page is
the tarball route and what analysts do.

## On a connected machine

Build or receive the offline bundle, `openbin-enterprise-<version>-offline.tar.gz`
(the `.run` file is the same bundle with the unpack step built in).
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

`--images` loads the archive into Docker instead of pulling. Leave out
`--domain` and `--admin-email` to be reached by IP address instead. Either
way the certificate comes from this install's own CA, which is what you
want without public DNS. Distribute the root certificate from
`bin/openbin-enterprise ca-cert` to analyst machines (`tls.md`).

## Analyst machines inside the air gap

Everything they need is served by the instance at
`https://app.<domain>/downloads/`:

```sh
curl -fsSL https://app.re.corp.example/downloads/install.sh | sh
openbin login --server https://api.re.corp.example
```

In the IP layout both are the OpenBin URL, and the machine has to trust
the install's CA first (or pass `-k` to that one `curl`):

```sh
curl -kO https://10.0.4.17/downloads/openbin-ca.crt     # then import it, see tls.md
curl -fsSL https://10.0.4.17/downloads/install.sh | sh
openbin login --server https://10.0.4.17
```

The install script served by the instance is rewritten to fetch from the
instance, and `--server` records where worker image tarballs come from, so
`openbin decompile` works with no path to the internet. Docker on the
analyst machine is still required for local decompiles; web uploads go
through the in-cluster workers and need nothing on the analyst side.

## Upgrades

Take a backup (`bin/openbin-enterprise backup`), then run the next
`.run` file the same way as the first. It finds the existing install in
`/opt/openbin-enterprise` (or `--dest`), keeps `.env` and all data, and
moves the stack to the new version.

From an offline tarball instead:

```sh
bin/openbin-enterprise upgrade --images openbin-enterprise-images-<new>.tar.gz
```

See `upgrade.md`.
