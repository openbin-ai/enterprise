# Analyst setup: the openbin CLI and BINNY

Native binaries are decompiled on the analyst's machine by the `openbin`
CLI (Ghidra in a local container) and the result is uploaded to the
instance. Android APKs can go either way: `openbin apk` locally, or a plain
web upload handled by the in-cluster JADX worker.

## Install from the instance

macOS / Linux:

```sh
curl -fsSL https://app.<domain>/downloads/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://app.<domain>/downloads/install.ps1 | iex
```

The scripts served by the instance already point at the instance for
downloads. Docker Desktop or Docker Engine is required for local
decompiles.

## Point the CLI at the instance

```sh
openbin login --server https://api.<domain>
```

Run once. The CLI asks the server for its sign-in host, web app hosts and
download location, stores them in `~/.config/openbin/server.json`, then
opens the browser device-flow sign-in. Every later command uses the saved
server. `openbin login --reset-server` returns to the hosted service.

If TLS is in internal mode the machine must trust the root certificate
first (`tls.md`), otherwise the CLI reports a certificate error.

## First decompile

```sh
openbin decompile ./sample.elf      # native
openbin apk ./app.apk               # Android, local JADX
```

The first run downloads the worker image tarball from
`https://app.<domain>/downloads/` (several hundred MB, cached afterwards).
The CLI prints the project URL on the instance when done.

## BINNY

The terminal agent installs the same way:

```sh
curl -fsSL https://app.<domain>/downloads/install-binny.sh | sh
```

BINNY talks to the model provider directly from the analyst machine. Use
its `/endpoint` command to point it at an internal gateway.
