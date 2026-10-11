#!/usr/bin/env bash
#
# Export every image the stack needs (ours + third-party) into one bundle
# for air-gapped installs:  dist/openbin-enterprise-images-<version>.tar.gz
#
#   scripts/save-images.sh [--version V] [--prefix ghcr.io/openbin-ai/enterprise]
#
# Third-party images are pulled for linux/amd64 first so the bundle is
# complete regardless of the build host's architecture.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/bin/lib.sh"
VERSION="$(cat "$HERE/VERSION")"; PREFIX="${IMAGE_PREFIX:-ghcr.io/openbin-ai/enterprise}"
while [ $# -gt 0 ]; do case "$1" in
  --version) VERSION="$2"; shift 2 ;; --prefix) PREFIX="$2"; shift 2 ;;
  *) die "unknown option $1" ;; esac; done

ours=(core frontend ghidra-worker jadx-worker script-worker pypi-worker shell-worker)
third=( $(grep -hoE '^\s+image: [^$ ]+' "$HERE/compose.yaml" | awk '{print $2}' | sort -u) )
images=()
for n in "${ours[@]}"; do images+=("$PREFIX/$n:$VERSION"); done
for i in "${third[@]}"; do
  info "pulling $i (linux/amd64)"; docker pull --platform linux/amd64 -q "$i" >/dev/null
  images+=("$i")
done
mkdir -p "$HERE/dist"
out="$HERE/dist/openbin-enterprise-images-$VERSION.tar.gz"
info "saving ${#images[@]} images to $out (several GB; this takes a while)"
docker save "${images[@]}" | gzip -1 > "$out"
sha256sum "$out" > "$out.sha256"
ok "$(du -h "$out" | cut -f1) written; checksum in $out.sha256"
