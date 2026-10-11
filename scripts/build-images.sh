#!/usr/bin/env bash
#
# Build every OpenBin Enterprise image from a platform checkout.
#
#   scripts/build-images.sh --platform-dir ~/Documents/GitHub/OpenAPK [--version V] [--only core,frontend] [--push]
#
# Images are tagged ${IMAGE_PREFIX}/<name>:<version> (default prefix
# ghcr.io/openbin-ai/enterprise, version from ./VERSION). The platform tree
# is staged into a temp dir without node_modules/target/.git so the build
# context stays small and untracked private packages (core/admin) come
# along exactly as they do for the hosted build.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/bin/lib.sh"

PLATFORM=""; VERSION="$(cat "$HERE/VERSION")"; ONLY=""; PUSH=0
PREFIX="${IMAGE_PREFIX:-ghcr.io/openbin-ai/enterprise}"
ARCH="${BUILD_PLATFORM:-linux/amd64}"
while [ $# -gt 0 ]; do case "$1" in
  --platform-dir) PLATFORM="$2"; shift 2 ;;
  --version) VERSION="$2"; shift 2 ;;
  --only) ONLY="$2"; shift 2 ;;
  --prefix) PREFIX="$2"; shift 2 ;;
  --push) PUSH=1; shift ;;
  -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option $1" ;; esac; done
[ -n "$PLATFORM" ] || PLATFORM="${PLATFORM_DIR:-}"
[ -d "$PLATFORM/core" ] || die "--platform-dir must point at the platform checkout (core/ not found under '$PLATFORM')"
command -v rsync >/dev/null || die "rsync is required"

want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }

CTX="$(mktemp -d)"; trap 'rm -rf "$CTX"' EXIT
info "staging platform tree into $CTX"
rsync -a --delete \
  --exclude node_modules --exclude dist --exclude target --exclude .git \
  --exclude workspace --exclude '.dev-*' --exclude '*.log' \
  "$PLATFORM/" "$CTX/"
mkdir -p "$CTX/images"; cp -r "$HERE/images/frontend" "$CTX/images/"

build() { # name dir [extra docker build args...]
  local name="$1" dir="$2"; shift 2
  local tag="$PREFIX/$name:$VERSION"
  info "building $tag"
  docker build --platform "$ARCH" -t "$tag" "$@" "$dir"
  [ "$PUSH" -eq 1 ] && docker push "$tag"
  return 0
}

want minio         && build minio         "$HERE/images/minio"
want core          && build core          "$CTX/core"
want frontend      && build frontend      "$CTX" -f "$CTX/images/frontend/Dockerfile"
want ghidra-worker && build ghidra-worker "$CTX/ghidra-worker"
want jadx-worker   && build jadx-worker   "$CTX/jadx-worker"
want script-worker && build script-worker "$CTX/script-worker"
want pypi-worker   && build pypi-worker   "$CTX/pypi-worker"
want shell-worker  && build shell-worker  "$CTX/shell-worker"
ok "built ${ONLY:-all images} as $PREFIX/*:$VERSION"
