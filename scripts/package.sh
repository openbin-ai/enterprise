#!/usr/bin/env bash
#
# Assemble the customer bundle:
#   dist/openbin-enterprise-<version>.tar.gz            installer, compose, config, docs
#   dist/openbin-enterprise-<version>-offline.tar.gz    the same + downloads/ + images bundle
#
#   scripts/package.sh [--offline]   (offline requires scripts/save-images.sh and fetch-downloads.sh to have run)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/bin/lib.sh"
VERSION="$(cat "$HERE/VERSION")"; OFFLINE=0
[ "${1:-}" = --offline ] && OFFLINE=1
mkdir -p "$HERE/dist"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
name="openbin-enterprise-$VERSION"
mkdir -p "$stage/$name"
tar -C "$HERE" --exclude .git --exclude dist --exclude .env --exclude 'config/Caddyfile' \
    --exclude 'config/keycloak/import/*.json' --exclude 'config/tls/*.pem' --exclude 'downloads/*' --exclude backups \
    -cf - . | tar -C "$stage/$name" -xf -
mkdir -p "$stage/$name/downloads"; touch "$stage/$name/downloads/.gitkeep"
if [ "$OFFLINE" -eq 1 ]; then
  imgs="$HERE/dist/openbin-enterprise-images-$VERSION.tar.gz"
  [ -f "$imgs" ] || die "run scripts/save-images.sh first ($imgs missing)"
  [ -f "$HERE/downloads/install.sh" ] || die "run scripts/fetch-downloads.sh first"
  cp -r "$HERE/downloads/." "$stage/$name/downloads/"
  cp "$imgs" "$imgs.sha256" "$stage/$name/"
  name_out="$name-offline"
else
  name_out="$name"
fi
out="$HERE/dist/$name_out.tar.gz"
tar -C "$stage" -czf "$out" "$name"
sha256sum "$out" > "$out.sha256"
ok "bundle: $out ($(du -h "$out" | cut -f1))"
