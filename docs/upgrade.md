# Upgrading

Releases are versioned as `YYYY.MM.N` (see `VERSION`). Upgrades are
in-place: the backend applies database migrations on boot, and nothing in
the object store changes shape.

Online:

```sh
bin/openbin-enterprise upgrade --version 2026.11.0
```

Offline:

```sh
bin/openbin-enterprise upgrade --images openbin-enterprise-images-2026.11.0.tar.gz
```

Either form takes a backup first (`backups/<timestamp>/`), updates
`OPENBIN_VERSION` in `.env`, re-renders configuration, restarts the
containers and waits for the backend's health check. Expect one to three
minutes of downtime.

When a release changes the installer, compose file or docs, unpack the new
bundle over the install directory before running `upgrade` (your `.env`,
`config/tls/` and `downloads/` are never part of the bundle, so they are
preserved). Release notes call this out when it applies.

Roll back by restoring the pre-upgrade backup and setting
`OPENBIN_VERSION` back in `.env`; database migrations are forward-only, so
a rollback is a restore, not a downgrade.
