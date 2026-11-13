#!/usr/bin/env bash
#
# Assemble the customer bundle:
#   dist/openbin-enterprise-<version>.tar.gz            installer, compose, config, docs
#   dist/openbin-enterprise-<version>-offline.tar.gz    the same + downloads/ + images bundle
#   dist/openbin-enterprise-<version>.run               the offline bundle as one self-extracting
#                                                       installer: copy one file, run it
#
#   scripts/package.sh [--offline | --run]
#   (--offline and --run require scripts/save-images.sh and fetch-downloads.sh to have run)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/bin/lib.sh"
VERSION="$(cat "$HERE/VERSION")"; OFFLINE=0; RUN=0
case "${1:-}" in
  --offline) OFFLINE=1 ;;
  --run) OFFLINE=1; RUN=1 ;;
  "") ;;
  *) die "unknown option $1" ;;
esac
mkdir -p "$HERE/dist"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
name="openbin-enterprise-$VERSION"
mkdir -p "$stage/$name"
tar -C "$HERE" --exclude .git --exclude dist --exclude .env --exclude 'config/Caddyfile' \
    --exclude 'config/keycloak/import/*.json' --exclude 'config/tls/*' --exclude 'config/.public-urls' --exclude 'config/.realm-settings' --exclude 'config/keycloak/truststores/*.pem' \
    --exclude 'downloads/*' --exclude backups \
    -cf - . | tar -C "$stage/$name" -xf -
mkdir -p "$stage/$name/downloads"; touch "$stage/$name/downloads/.gitkeep"
if [ "$OFFLINE" -eq 1 ]; then
  imgs="$HERE/dist/openbin-enterprise-images-$VERSION.tar.gz"
  [ -f "$imgs" ] || die "run scripts/save-images.sh first ($imgs missing)"
  [ -f "$HERE/downloads/install.sh" ] || die "run scripts/fetch-downloads.sh first"
  cp -r "$HERE/downloads/." "$stage/$name/downloads/"
  # A CA from a test install on the build machine must never ship.
  rm -f "$stage/$name/downloads/openbin-ca.crt"
  cp "$imgs" "$imgs.sha256" "$stage/$name/"
  name_out="$name-offline"
else
  name_out="$name"
fi
mkdir -p "$stage/$name/config/tls"; touch "$stage/$name/config/tls/.gitkeep"
if [ "$RUN" -eq 1 ]; then
  # Header script + plain tar (the images inside are already compressed).
  out="$HERE/dist/$name.run"
  payload="$HERE/dist/.payload-$VERSION.tar"
  info "building the payload"
  tar -C "$stage" --owner=0 --group=0 -cf "$payload" "$name"
  sha="$(sha256sum "$payload" | cut -d' ' -f1)"
  kb="$(du -k "$payload" | cut -f1)"
  line=$(( $(wc -l < "$HERE/scripts/run-header.sh") + 1 ))
  sed -e "s/@VERSION@/$VERSION/g" -e "s/@NAME@/$name/g" -e "s/@SHA256@/$sha/" \
      -e "s/@LINE@/$line/" -e "s/@KB@/$kb/" "$HERE/scripts/run-header.sh" > "$out"
  cat "$payload" >> "$out"; rm -f "$payload"
  chmod +x "$out"
  (cd "$HERE/dist" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
  ok "installer: $out ($(du -h "$out" | cut -f1))"
  exit 0
fi
out="$HERE/dist/$name_out.tar.gz"
tar -C "$stage" -czf "$out" "$name"
sha256sum "$out" > "$out.sha256"
ok "bundle: $out ($(du -h "$out" | cut -f1))"
