#!/usr/bin/env bash
# Re-copy the files this repo vendors from the platform checkout (Keycloak
# login theme). Run after the theme changes upstream, then commit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="${1:-${PLATFORM_DIR:-}}"; [ -d "$P/core/docker/keycloak/themes" ] || { echo "usage: $0 <platform-dir>" >&2; exit 2; }
rm -rf "$HERE/config/keycloak/themes" && cp -r "$P/core/docker/keycloak/themes" "$HERE/config/keycloak/themes"
echo "synced keycloak themes from $P"
