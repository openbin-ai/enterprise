#!/bin/sh
# Create the two buckets the platform expects. Waits for MinIO to answer
# (compose starts both at once), then exits 0 so `core` can start.
set -eu
i=0
until mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
  i=$((i+1))
  [ "$i" -ge 60 ] && { echo "minio-init: MinIO did not come up in 120s" >&2; exit 1; }
  sleep 2
done
for b in openbin-media openbin-analysis; do
  mc mb --ignore-existing "local/$b"
  mc anonymous set none "local/$b"
done
echo "minio-init: buckets ready"
