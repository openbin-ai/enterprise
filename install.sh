#!/usr/bin/env bash
#
# OpenBin Enterprise installer.
#
#   ./install.sh                         # interactive
#   ./install.sh --domain re.corp.example --admin-email you@corp.example --yes
#   ./install.sh --images openbin-enterprise-images-2026.10.0.tar.gz ...   # air-gapped
#
# What it does, in order:
#   1. checks Docker + Compose v2, memory, disk, and that :80/:443 are free;
#   2. writes .env with your hostnames, TLS choice and freshly generated
#      secrets (never overwrites an existing .env without --force);
#   3. renders config/Caddyfile and the Keycloak realm from .env;
#   4. loads the image bundle (--images) or pulls from the registry;
#   5. starts the stack and waits for the backend to report healthy;
#   6. prints the URLs, the DNS records you need, and how to trust the CA.
#
# Re-running is safe: with an existing .env it only re-renders and restarts.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
# shellcheck source=bin/lib.sh
. "$HERE/bin/lib.sh"

DOMAIN=""; ADMIN_EMAIL=""; TLS_MODE=""; ACME_EMAIL=""; CERT=""; KEY=""
IMAGES=""; REGISTRY_USER=""; REGISTRY_TOKEN=""; YES=0; FORCE=0; NO_START=0
SELF_REG=""; VERSION_OVERRIDE=""; HTTP_PORT=80; HTTPS_PORT=443

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; cat <<USAGE

Options:
  --domain D            base domain; hostnames become app.D apk.D api.D auth.D s3.D
  --admin-email E       first administrator (platform admin + Keycloak admin login)
  --tls MODE            internal (default, own CA) | acme (Let's Encrypt) | custom
  --acme-email E        contact for Let's Encrypt (acme mode)
  --cert F --key F      PEM files for *.D (custom mode)
  --images FILE         docker image bundle for air-gapped installs (docker save output)
  --registry-user U --registry-token T
                        credentials for ghcr.io when pulling (online installs)
  --self-registration   let users create their own accounts (default: off)
  --version V           override the image tag in VERSION
  --http-port N --https-port N
                        host ports for the proxy (default 80/443)
  --no-start            write config only, do not start containers
  --force               overwrite an existing .env (secrets are regenerated!)
  --yes                 no prompts; fail if something required is missing
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --tls) TLS_MODE="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --cert) CERT="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --images) IMAGES="$2"; shift 2 ;;
    --registry-user) REGISTRY_USER="$2"; shift 2 ;;
    --registry-token) REGISTRY_TOKEN="$2"; shift 2 ;;
    --self-registration) SELF_REG=true; shift ;;
    --version) VERSION_OVERRIDE="$2"; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

banner "OpenBin Enterprise $(cat VERSION)"

# ---- 1. preflight -----------------------------------------------------------
require_docker
mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
[ "$mem_gb" -ge 15 ] || warn "this host has ${mem_gb} GiB RAM; 16 GiB is the minimum for Ghidra + JADX side by side (see docs/sizing.md)"
disk_gb=$(df -BG --output=avail "$HERE" | tail -1 | tr -dc '0-9')
[ "$disk_gb" -ge 60 ] || warn "only ${disk_gb} GiB free under $HERE; samples and decompiled trees add up quickly"
if [ "$NO_START" -ne 1 ]; then
  for p in "$HTTP_PORT" "$HTTPS_PORT"; do
    port_in_use "$p" && die "port $p is already in use on this host; stop the other web server or pass --http-port/--https-port"
  done
fi

# ---- 2. .env ---------------------------------------------------------------
if [ -f .env ] && [ "$FORCE" -ne 1 ]; then
  info "existing .env found; keeping it (use --force to regenerate secrets)"
  load_env
else
  if [ -z "$DOMAIN" ]; then
    [ "$YES" -eq 1 ] && die "--domain is required with --yes"
    read -r -p "Base domain (hostnames become app.<domain>, api.<domain>, ...): " DOMAIN
  fi
  DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*$##')"
  [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || die "'$DOMAIN' is not a hostname"
  if [ -z "$ADMIN_EMAIL" ]; then
    [ "$YES" -eq 1 ] && die "--admin-email is required with --yes"
    read -r -p "Administrator email: " ADMIN_EMAIL
  fi
  [[ "$ADMIN_EMAIL" == *@* ]] || die "'$ADMIN_EMAIL' is not an email address"
  if [ -z "$TLS_MODE" ]; then
    if [ "$YES" -eq 1 ]; then TLS_MODE=internal; else
      echo "TLS:"
      echo "  1) internal  - certificates from this install's own CA (air-gapped default)"
      echo "  2) acme      - Let's Encrypt (host must be reachable from the internet)"
      echo "  3) custom    - I have a certificate for *.$DOMAIN"
      read -r -p "Choice [1]: " c; case "${c:-1}" in 2) TLS_MODE=acme ;; 3) TLS_MODE=custom ;; *) TLS_MODE=internal ;; esac
    fi
  fi
  case "$TLS_MODE" in
    internal) ;;
    acme) [ -n "$ACME_EMAIL" ] || { [ "$YES" -eq 1 ] && die "--acme-email is required for acme"; read -r -p "Let's Encrypt contact email: " ACME_EMAIL; } ;;
    custom)
      [ -n "$CERT" ] || { [ "$YES" -eq 1 ] && die "--cert/--key are required for custom"; read -r -p "Path to fullchain.pem: " CERT; }
      [ -n "$KEY" ] || read -r -p "Path to privkey.pem: " KEY
      [ -f "$CERT" ] && [ -f "$KEY" ] || die "certificate or key file not found"
      install -m 0644 "$CERT" config/tls/fullchain.pem
      install -m 0600 "$KEY" config/tls/privkey.pem ;;
    *) die "--tls must be internal, acme or custom" ;;
  esac

  info "writing .env"
  kc_pw="$(random_token 20)"
  cat > .env <<ENV
# OpenBin Enterprise — generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by install.sh
# See .env.example for what each value does. chmod 600; contains secrets.
OPENBIN_VERSION=${VERSION_OVERRIDE:-$(cat VERSION)}
IMAGE_PREFIX=ghcr.io/openbin-ai/enterprise

OPENBIN_DOMAIN=$DOMAIN
APP_HOST=app.$DOMAIN
APK_HOST=apk.$DOMAIN
API_HOST=api.$DOMAIN
AUTH_HOST=auth.$DOMAIN
S3_HOST=s3.$DOMAIN
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT

TLS_MODE=$TLS_MODE
ACME_EMAIL=$ACME_EMAIL

ADMIN_EMAIL=$ADMIN_EMAIL
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$kc_pw

SELF_REGISTRATION=${SELF_REG:-false}
TOS_REQUIRED=false
LLM_EGRESS_ALLOWLIST=

POSTGRES_PASSWORD=$(random_token 32)
KEYCLOAK_DB_PASSWORD=$(random_token 32)
MINIO_ROOT_USER=openbin
MINIO_ROOT_PASSWORD=$(random_token 32)
OPENAPK_KEK_B64=$(openssl rand -base64 32)
JADX_WORKER_TOKEN=$(random_token 32)
KEYCLOAK_CORE_CLIENT_SECRET=$(random_token 32)

CORE_MEM=3g
GHIDRA_MEM=8g
JADX_MEM=6g
ENV
  chmod 600 .env
  load_env
fi

# ---- 3. render -------------------------------------------------------------
render_all
if [ "$NO_START" -eq 1 ]; then
  info "--no-start: configuration written, nothing pulled or started."
  print_summary; exit 0
fi

# ---- 4. images -------------------------------------------------------------
if [ -n "$IMAGES" ]; then
  [ -f "$IMAGES" ] || die "image bundle not found: $IMAGES"
  info "loading images from $IMAGES (this takes a few minutes)"
  load_images "$IMAGES"
else
  if [ -n "$REGISTRY_TOKEN" ]; then
    info "logging in to ghcr.io"
    echo "$REGISTRY_TOKEN" | docker login ghcr.io -u "${REGISTRY_USER:-openbin-customer}" --password-stdin
  fi
  info "pulling images for ${OPENBIN_VERSION} (needs access to ghcr.io/openbin-ai/enterprise)"
  compose pull
fi

# ---- 5. start --------------------------------------------------------------
info "starting the stack"
compose up -d --remove-orphans
wait_for_core 600

# ---- 6. summary ------------------------------------------------------------
print_summary
