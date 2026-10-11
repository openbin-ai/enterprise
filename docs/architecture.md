# Architecture

```
                 analyst browser / openbin CLI / BINNY
                                 │ https
        ┌────────────────────────┴────────────────────────┐
        │ proxy (Caddy)   app. apk. api. auth. s3.<domain> │
        └──┬──────────┬──────────┬──────────┬──────────┬──┘
           │          │          │          │          │
       frontend   frontend     core     keycloak     minio
       :8080      :8081       :8081      :8080       :9000
       (OpenBin)  (OpenAPK)     │          │           ▲
                                ├──────────┘ JWKS      │ S3 API
                                ├──────────────────────┘
                                ├── postgres  (openapk, keycloak databases)
                                ├── ghidra-worker :8000
                                ├── jadx-worker   :8000  (X-Worker-Token)
                                └── script-worker / pypi-worker / shell-worker :8080
                                    (Lambda images under the runtime emulator)
```

All inter-container traffic is plain HTTP on the compose network; only the
proxy listens on the host.

## Differences from the hosted service

| Concern | Hosted (openbin.ai) | This distribution |
|---|---|---|
| Decompilers | paused; CLI only | running in-cluster; web uploads work |
| Script analyzers | AWS Lambda | same images over HTTP (`OPENAPK_SCRIPT_ANALYZER_MODE=http`) |
| Object storage | S3 + CloudFront signed URLs | MinIO; presigned URLs via `s3.<domain>` |
| Frontend endpoints | baked at build time | `/openbin-config.js` written at container start |
| Token validation | OIDC discovery | public issuer name, keys fetched internally |
| Terms of Service gate | on | off (`TOS_REQUIRED`) |
| Worker quota | daily cap per user | unlimited |
| Email notifications | SES | disabled (Keycloak SMTP still available) |
| BYOK egress | public destinations only | plus `LLM_EGRESS_ALLOWLIST` |
| CLI target | compiled-in | `openbin login --server` |

## Images

All images except Postgres, Keycloak and Caddy are built by `scripts/build-images.sh` and published under `ghcr.io/openbin-ai/enterprise`. That includes MinIO, compiled from the upstream source tag (`images/minio`): MinIO stopped publishing community images and binaries in 2025.

## Data

- Postgres `openapk`: users, projects, reports, highlights, chats, encrypted API keys.
- Postgres `keycloak`: identities and sessions.
- MinIO `openbin-media`: samples, decompiled trees, screenshots.
- MinIO `openbin-analysis`: Ghidra results, script bundles.
- `openbin_core-workspace`: a disposable local cache in front of MinIO.

## Security notes

- Secrets exist only in `.env` (mode 600) and the Keycloak realm import
  rendered from it. Rotate by editing `.env` and running `up`; the
  encryption key `OPENAPK_KEK_B64` cannot be rotated without re-entering
  stored API keys.
- The JADX worker requires a shared token; the Ghidra worker and script
  workers are reachable only on the compose network.
- The backend's SSRF policy for user-supplied model endpoints stays on;
  the allowlist is the only widening and is logged at boot.
