#!/usr/bin/env bash
#
# OpenBin Enterprise @VERSION@ — self-contained installer.
#
# Everything is inside this one file: the installer, every container image,
# the CLI and BINNY downloads. The host needs Docker (with Compose v2) and
# no network access.
#
#   ./@NAME@.run                          install, reached by this host's IP address
#   ./@NAME@.run --ip 10.0.4.17 --openbin-port 8443 --openapk-port 8444
#   ./@NAME@.run --help                   every option
#
# Options handled here (all others go to install.sh):
#   --dest DIR        where to install (default /opt/openbin-enterprise as root,
#                     otherwise ~/openbin-enterprise; an existing install is upgraded in place)
#   --extract-only    unpack to --dest and stop
#   --no-verify       skip the payload checksum
#   --keep-images     keep the unpacked image bundle after loading it (several GB)
set -euo pipefail
VERSION="@VERSION@"; PAYLOAD_SHA256="@SHA256@"; PAYLOAD_LINE=@LINE@; PAYLOAD_KB=@KB@
SELF="$0"
say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

DEST=""; VERIFY=1; EXTRACT_ONLY=0; KEEP=0; HELP=0; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) [ $# -ge 2 ] || die "--dest needs a directory"; DEST="$2"; shift 2 ;;
    --extract-only) EXTRACT_ONLY=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --keep-images) KEEP=1; shift ;;
    -h|--help) HELP=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
payload() { tail -n +"$PAYLOAD_LINE" "$SELF"; }

if [ "$HELP" -eq 1 ]; then
  sed -n '3,18p' "$SELF" | sed 's/^# \{0,1\}//'
  echo; echo "install.sh options:"; echo
  tmp="$(mktemp -d)"
  payload | tar -x -C "$tmp" --strip-components=1 --occurrence=1 \
    "openbin-enterprise-$VERSION/install.sh" "openbin-enterprise-$VERSION/bin/lib.sh" "openbin-enterprise-$VERSION/VERSION" 2>/dev/null || true
  [ ! -f "$tmp/install.sh" ] || "$tmp/install.sh" --help | sed -n '/^Reached by IP/,$p'
  rm -rf "$tmp"
  exit 0
fi

if [ -z "$DEST" ]; then
  if [ "$(id -u)" -eq 0 ]; then DEST=/opt/openbin-enterprise; else DEST="$HOME/openbin-enterprise"; fi
fi

# Fail on the cheap checks before unpacking several GB.
if [ "$EXTRACT_ONLY" -ne 1 ]; then
  command -v docker >/dev/null 2>&1 || die "docker is not installed; it is the one thing this installer needs"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running? try: sudo $SELF)"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required ('docker compose')"
fi
mkdir -p "$DEST" || die "cannot create $DEST (try --dest DIR)"
free_kb="$(df -Pk "$DEST" | awk 'NR==2 {print $4}')"
[ "$free_kb" -ge $((PAYLOAD_KB + 1048576)) ] || die "not enough space in $DEST: need $(( (PAYLOAD_KB + 1048576) / 1048576 )) GiB, have $(( free_kb / 1048576 )) GiB (try --dest DIR)"

if [ "$VERIFY" -eq 1 ]; then
  say "verifying the bundle (--no-verify to skip)"
  got="$(payload | sha256sum | cut -d' ' -f1)"
  [ "$got" = "$PAYLOAD_SHA256" ] || die "checksum mismatch: this file is damaged or incomplete; copy it again"
fi

say "unpacking OpenBin Enterprise $VERSION into $DEST"
payload | tar -x -C "$DEST" --strip-components=1 --no-same-owner
[ "$EXTRACT_ONLY" -ne 1 ] || { say "unpacked; run $DEST/install.sh --images $DEST/openbin-enterprise-images-$VERSION.tar.gz"; exit 0; }

images="$DEST/openbin-enterprise-images-$VERSION.tar.gz"
"$DEST/install.sh" --images "$images" "${args[@]+"${args[@]}"}"
if [ "$KEEP" -ne 1 ]; then rm -f "$images" "$images.sha256"; fi
say "installed in $DEST; manage it with $DEST/bin/openbin-enterprise"
exit 0
# ---- payload (tar) follows; do not edit below this line ----
