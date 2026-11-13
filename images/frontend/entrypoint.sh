#!/bin/sh
# Runs before nginx starts (official image hook). Two jobs:
#   1. write one runtime config per web app from the compose env. The two
#      apps can be given different endpoints: in the IP layout each one
#      reaches the backend and sign-in discovery through its own origin;
#   2. expose the mounted downloads/ directory, rewriting the install
#      scripts so `curl ... | sh` fetches from this instance, not GitHub.
set -eu

: "${APP_URL:?APP_URL is required (public URL of the OpenBin web app)}"
: "${API_URL:?API_URL is required (public URL of the backend)}"
: "${AUTH_URL:?AUTH_URL is required (public URL of Keycloak)}"
APK_API_URL="${APK_API_URL:-$API_URL}"
APK_AUTH_URL="${APK_AUTH_URL:-$AUTH_URL}"

DOWNLOADS_URL="${APP_URL}/downloads"
write_config() { # file api auth
  cat > "$1" <<JS
window.__OPENBIN_CONFIG__ = {
  apiBase: "$2",
  authority: "$3/realms/openapk",
  installBase: "${DOWNLOADS_URL}",
  selfHosted: true
};
JS
}
write_config /run/openbin/openbin-config.js "$API_URL" "$AUTH_URL"
write_config /run/openbin/openapk-config.js "$APK_API_URL" "$APK_AUTH_URL"

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
echo "openbin frontend: api=${API_URL} auth=${AUTH_URL} downloads=${DOWNLOADS_URL}"
