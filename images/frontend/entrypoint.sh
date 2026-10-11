#!/bin/sh
# Runs before nginx starts (official image hook). Two jobs:
#   1. write /run/openbin/openbin-config.js from the compose env;
#   2. expose the mounted downloads/ directory, rewriting the install
#      scripts so `curl ... | sh` fetches from this instance, not GitHub.
set -eu

: "${APP_HOST:?APP_HOST is required}"
: "${APK_HOST:?APK_HOST is required}"
: "${API_HOST:?API_HOST is required}"
: "${AUTH_HOST:?AUTH_HOST is required}"

DOWNLOADS_URL="https://${APP_HOST}/downloads"
cat > /run/openbin/openbin-config.js <<JS
window.__OPENBIN_CONFIG__ = {
  apiBase: "https://${API_HOST}",
  authority: "https://${AUTH_HOST}/realms/openapk",
  installBase: "${DOWNLOADS_URL}",
  selfHosted: true
};
JS

SRC=/usr/share/openbin/downloads
DST=/run/openbin/downloads
rm -rf "$DST" && mkdir -p "$DST"
if [ -d "$SRC" ]; then
  # Symlink everything (worker tarballs are large), then replace the four
  # install scripts with copies whose default release base is this host.
  for f in "$SRC"/* "$SRC"/.[!.]*; do
    [ -e "$f" ] || continue
    ln -s "$f" "$DST/$(basename "$f")"
  done
  for s in install.sh install.ps1; do
    if [ -f "$SRC/$s" ]; then
      rm -f "$DST/$s"
      sed "s#https://github.com/\$REPO/releases/latest/download#${DOWNLOADS_URL}#g; s#https://github.com/\$repo/releases/latest/download#${DOWNLOADS_URL}#g; s#https://openbin.ai/install#${DOWNLOADS_URL}/install#g" \
        "$SRC/$s" > "$DST/$s"
    fi
  done
  for s in install-binny.sh install-binny.ps1; do
    if [ -f "$SRC/$s" ]; then
      rm -f "$DST/$s"
      sed "s#https://github.com/\$REPO/releases/latest/download#${DOWNLOADS_URL}/binny#g; s#https://github.com/\$repo/releases/latest/download#${DOWNLOADS_URL}/binny#g; s#https://openbin.ai/install-binny#${DOWNLOADS_URL}/install-binny#g" \
        "$SRC/$s" > "$DST/$s"
    fi
  done
fi
echo "openbin frontend: api=https://${API_HOST} auth=https://${AUTH_HOST} downloads=${DOWNLOADS_URL}"
