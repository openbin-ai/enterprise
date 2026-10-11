#!/usr/bin/env bash
#
# Populate downloads/ with everything analysts install from the instance:
# the openbin CLI for every platform, the worker image tarballs the CLI
# loads for local decompiles, BINNY, and the four install scripts. Run on a
# machine with internet access; downloads/ ships inside the bundle.
#
#   scripts/fetch-downloads.sh --platform-dir ~/Documents/GitHub/OpenAPK [--cli-tag openbin-v0.10.0] [--binny-tag v0.1.0-beta.1]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/bin/lib.sh"
PLATFORM="${PLATFORM_DIR:-}"; CLI_TAG="latest"; BINNY_TAG="latest"
while [ $# -gt 0 ]; do case "$1" in
  --platform-dir) PLATFORM="$2"; shift 2 ;;
  --cli-tag) CLI_TAG="$2"; shift 2 ;;
  --binny-tag) BINNY_TAG="$2"; shift 2 ;;
  *) die "unknown option $1" ;; esac; done
[ -d "$PLATFORM/openbin-landing/public" ] || die "--platform-dir must point at the platform checkout"

D="$HERE/downloads"; mkdir -p "$D/binny"
base() { # repo tag
  if [ "$2" = latest ]; then echo "https://github.com/$1/releases/latest/download"; else echo "https://github.com/$1/releases/download/$2"; fi
}
get() { info "  $(basename "$2")"; curl -fsSL --retry 3 -o "$2" "$1"; }

info "openbin CLI + worker images ($CLI_TAG)"
B="$(base openbin-ai/platform "$CLI_TAG")"
for a in openbin-linux-amd64.tar.gz openbin-linux-arm64.tar.gz openbin-darwin-amd64.tar.gz openbin-darwin-arm64.tar.gz openbin-windows-amd64.zip ghidra-worker.tar.gz jadx-worker.tar.gz VERSION; do
  get "$B/$a" "$D/$a"
done
info "BINNY ($BINNY_TAG)"
B="$(base openbin-ai/binny-releases "$BINNY_TAG")"
for a in binny-linux-amd64.tar.gz binny-linux-arm64.tar.gz binny-darwin-amd64.tar.gz binny-darwin-arm64.tar.gz binny-windows-amd64.zip VERSION; do
  get "$B/$a" "$D/binny/$a"
done
info "install scripts from the platform checkout"
for s in install.sh install.ps1 install-binny.sh install-binny.ps1; do
  cp "$PLATFORM/openbin-landing/public/$s" "$D/$s"
done
(cd "$D" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + | sort -k2 > SHA256SUMS)
ok "downloads/ ready ($(du -sh "$D" | cut -f1))"
