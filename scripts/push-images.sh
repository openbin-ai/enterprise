#!/usr/bin/env bash
# Push the built images to the private registry. Requires `docker login ghcr.io`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/bin/lib.sh"
VERSION="${1:-$(cat "$HERE/VERSION")}"; PREFIX="${IMAGE_PREFIX:-ghcr.io/openbin-ai/enterprise}"
for n in core frontend ghidra-worker jadx-worker script-worker pypi-worker shell-worker; do
  info "pushing $PREFIX/$n:$VERSION"; docker push "$PREFIX/$n:$VERSION"
done
ok "pushed $VERSION"
