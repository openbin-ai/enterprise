# Backup and restore

```sh
bin/openbin-enterprise backup            # → backups/<timestamp>/
bin/openbin-enterprise backup /mnt/nas/openbin/$(date +%F)
```

A backup directory contains:

- `openapk.dump`, `keycloak.dump`: `pg_dump` custom-format archives of both databases;
- `openbin-media/`, `openbin-analysis/`: a mirror of the two object-store buckets;
- `env.backup`: your `.env`. It holds `OPENAPK_KEK_B64`, the key that
  encrypts users' stored API keys. Without it a restored database has
  unreadable credentials. Treat the backup directory as secret.
- `VERSION`: the release the backup was taken from.

Backups run online. Object mirroring is incremental, so a nightly cron job
against the same destination transfers only what changed.

Also keep the Caddy volume if you use the internal CA, so a rebuilt host
does not need a new root certificate on every client:

```sh
docker run --rm -v openbin_caddy-data:/data -v "$PWD":/out alpine tar czf /out/caddy-data.tgz -C /data .
```

## Restore

On a host with the same release installed (`.env` restored from
`env.backup`, images present):

```sh
bin/openbin-enterprise down
bin/openbin-enterprise restore /path/to/backup
bin/openbin-enterprise up
```

Restore replaces both databases and both buckets. If the backup is from an
older release, start the stack afterwards and the backend applies the
remaining migrations on boot.
