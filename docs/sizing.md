# Sizing

The decompilers dominate. Ghidra and JADX each hold a whole binary in
memory, and large samples (games, firmware images) push both toward their
limits.

| Team | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|
| Evaluation, 1–3 analysts | 4 | 16 GiB | 100 GiB | one decompile at a time |
| Small team, up to 10 | 8 | 32 GiB | 250 GiB | default memory limits |
| Department, 10–50 | 16 | 64 GiB | 1 TiB | raise `GHIDRA_MEM`/`JADX_MEM`, consider SSD |

Memory limits per container are in `.env` (`CORE_MEM`, `GHIDRA_MEM`,
`JADX_MEM`). The script analyzers are small. Keycloak, Postgres and MinIO
together stay under 2 GiB at these sizes.

Disk grows with uploaded samples, decompiled source trees and analysis
results, all in the `openbin_minio-data` volume, plus a working cache in
`openbin_core-workspace`. Put `/var/lib/docker` on the largest volume.

Analysts who decompile locally with the CLI offload the heaviest work to
their own machines; a team that works that way can run at the smaller end
of the table.
