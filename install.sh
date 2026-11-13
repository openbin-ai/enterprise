#!/usr/bin/env bash
#
# OpenBin Enterprise installer. The host needs Docker (with Compose v2) and
# nothing else.
#
#   ./install.sh                                   # by IP address, no DNS, no questions
#   ./install.sh --ip 10.0.4.17 --openbin-port 8443 --openapk-port 8444
#   ./install.sh --domain re.corp.example --admin-email you@corp.example
#   ./install.sh --images openbin-enterprise-images-<version>.tar.gz ...   # air-gapped
#
# What it does, in order:
#   1. checks Docker + Compose v2, memory and disk;
#   2. writes .env with the address, ports and freshly generated secrets
#      (an existing .env is kept; flags given on a re-run update it);
#   3. loads the image bundle (--images) or pulls from the registry;
#   4. issues the TLS certificate and renders the proxy and sign-in config;
#   5. starts the stack and waits for the backend to report healthy;
#   6. prints the URLs and the first sign-in.
#
# Re-running is safe and is how you change the address or ports later.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
# shellcheck source=bin/lib.sh
. "$HERE/bin/lib.sh"

DOMAIN=""; IP=""; ADMIN_EMAIL_ARG=""; TLS_MODE_ARG=""; ACME_EMAIL=""; CERT=""; KEY=""
IMAGES=""; REGISTRY_USER=""; REGISTRY_TOKEN=""; YES=0; FORCE=0; NO_START=0
SELF_REG=""; VERSION_OVERRIDE=""; HTTP_PORT_ARG=""; HTTPS_PORT_ARG=""
OPENBIN_PORT_ARG=""; OPENAPK_PORT_ARG=""; LLM_ALLOW=""; EXTRA_SANS=""
LDAP_URL=""; LDAP_BIND_DN=""; LDAP_PW_FILE=""; LDAP_USERS_DN=""; LDAP_VENDOR="other"
LDAP_USER_ATTR=""; LDAP_FILTER=""; LDAP_CA=""

usage() { sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; cat <<USAGE

Reached by IP address (default):
  --ip ADDR             address users type in the browser (default: auto-detected)
  --openbin-port N      HTTPS port for OpenBin (default 443)
  --openapk-port N      HTTPS port for OpenAPK (default 8443)
                        These two ports are the only ones exposed; pick any
                        that your network allows.
  --san NAME[,NAME]     extra IPs or DNS names to put in the certificate

Reached by DNS names:
  --domain D            base domain; hostnames become app.D apk.D api.D auth.D s3.D
  --tls MODE            internal (default, own CA) | acme (Let's Encrypt) | custom
  --acme-email E        contact for Let's Encrypt (acme mode)
  --http-port N --https-port N
                        host ports for the proxy (default 80/443)

Both:
  --cert F --key F      use your own certificate (PEM) instead of a generated one
  --admin-email E       first administrator (default in IP mode: admin@openbin.local)
  --llm-allow LIST      hosts or CIDRs of model servers on your network that
                        users may add as OpenAI-compatible providers
  --images FILE         docker image bundle for air-gapped installs (docker save output)
  --registry-user U --registry-token T
                        credentials for ghcr.io when pulling (online installs)

Accounts:
  --self-registration / --no-self-registration
                        whether people can create their own accounts on the
                        sign-in page (default: on by IP address, off with --domain)
  --ldap-url URL        sign in with your directory: ldap://host:389 or ldaps://host:636
  --ldap-bind-dn DN     read-only account used to look people up
  --ldap-bind-password-file FILE
                        file holding that account's password (or set
                        LDAP_BIND_PASSWORD in the environment)
  --ldap-users-dn DN    where people live, e.g. ou=People,dc=corp,dc=example
  --ldap-vendor V       ad (Active Directory) | other (default: OpenLDAP, 389-DS, FreeIPA)
  --ldap-username-attr A   default sAMAccountName for ad, uid otherwise
  --ldap-filter F       optional LDAP filter, e.g. (memberOf=cn=re-team,ou=Groups,dc=corp,dc=example)
  --ldap-ca-cert FILE   CA that signed the directory's ldaps:// certificate
                        (later: bin/openbin-enterprise ldap connect|sync|status|remove)

  --version V           override the image tag in VERSION
  --no-start            write config only, do not start containers
  --force               overwrite an existing .env (secrets are regenerated!)
  --yes                 accepted for compatibility; the installer never prompts
USAGE
}

need() { [ $# -ge 2 ] || die "$1 needs a value (try --help)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) need "$@"; DOMAIN="$2"; shift 2 ;;
    --ip|--host) need "$@"; IP="$2"; shift 2 ;;
    --openbin-port) need "$@"; OPENBIN_PORT_ARG="$2"; shift 2 ;;
    --openapk-port) need "$@"; OPENAPK_PORT_ARG="$2"; shift 2 ;;
    --san) need "$@"; EXTRA_SANS="$2"; shift 2 ;;
    --admin-email) need "$@"; ADMIN_EMAIL_ARG="$2"; shift 2 ;;
    --tls) need "$@"; TLS_MODE_ARG="$2"; shift 2 ;;
    --acme-email) need "$@"; ACME_EMAIL="$2"; shift 2 ;;
    --cert) need "$@"; CERT="$2"; shift 2 ;;
    --key) need "$@"; KEY="$2"; shift 2 ;;
    --llm-allow) need "$@"; LLM_ALLOW="$2"; shift 2 ;;
    --images) need "$@"; IMAGES="$2"; shift 2 ;;
    --registry-user) need "$@"; REGISTRY_USER="$2"; shift 2 ;;
    --registry-token) need "$@"; REGISTRY_TOKEN="$2"; shift 2 ;;
    --self-registration) SELF_REG=true; shift ;;
    --no-self-registration) SELF_REG=false; shift ;;
    --ldap-url) need "$@"; LDAP_URL="$2"; shift 2 ;;
    --ldap-bind-dn) need "$@"; LDAP_BIND_DN="$2"; shift 2 ;;
    --ldap-bind-password-file) need "$@"; LDAP_PW_FILE="$2"; shift 2 ;;
    --ldap-users-dn) need "$@"; LDAP_USERS_DN="$2"; shift 2 ;;
    --ldap-vendor) need "$@"; LDAP_VENDOR="$2"; shift 2 ;;
    --ldap-username-attr) need "$@"; LDAP_USER_ATTR="$2"; shift 2 ;;
    --ldap-filter) need "$@"; LDAP_FILTER="$2"; shift 2 ;;
    --ldap-ca-cert) need "$@"; LDAP_CA="$2"; shift 2 ;;
    --version) need "$@"; VERSION_OVERRIDE="$2"; shift 2 ;;
    --http-port) need "$@"; HTTP_PORT_ARG="$2"; shift 2 ;;
    --https-port) need "$@"; HTTPS_PORT_ARG="$2"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

for p in "$OPENBIN_PORT_ARG" "$OPENAPK_PORT_ARG" "$HTTP_PORT_ARG" "$HTTPS_PORT_ARG"; do
  [ -z "$p" ] || valid_port "$p" || die "'$p' is not a port number (1-65535)"
done
[ -z "$DOMAIN" ] || [ -z "$IP" ] || die "--domain and --ip are two different layouts; pass one"
[ -n "$CERT" ] && [ -z "$KEY" ] && die "--cert needs --key"
[ -n "$KEY" ] && [ -z "$CERT" ] && die "--key needs --cert"
if [ -n "$CERT" ]; then [ -f "$CERT" ] && [ -f "$KEY" ] || die "certificate or key file not found"; fi
[ -z "$IMAGES" ] || [ -f "$IMAGES" ] || die "image bundle not found: $IMAGES"
LDAP_PW=""
if [ -n "$LDAP_URL" ]; then
  [ -n "$LDAP_BIND_DN" ] && [ -n "$LDAP_USERS_DN" ] || die "--ldap-url also needs --ldap-bind-dn and --ldap-users-dn"
  if [ -n "$LDAP_PW_FILE" ]; then
    [ -f "$LDAP_PW_FILE" ] || die "password file not found: $LDAP_PW_FILE"
    LDAP_PW="$(head -n 1 "$LDAP_PW_FILE" | tr -d '\r\n')"
  else LDAP_PW="${LDAP_BIND_PASSWORD:-}"; fi
  [ -n "$LDAP_PW" ] || die "the LDAP bind password is missing: pass --ldap-bind-password-file FILE or set LDAP_BIND_PASSWORD"
  [ -z "$LDAP_CA" ] || [ -f "$LDAP_CA" ] || die "CA certificate not found: $LDAP_CA"
  [ "$NO_START" -ne 1 ] || die "--ldap-url needs the stack running; drop --no-start"
fi

banner "OpenBin Enterprise $(cat VERSION)"

# ---- 1. preflight -----------------------------------------------------------
require_docker
mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
[ "$mem_gb" -ge 15 ] || warn "this host has ${mem_gb} GiB RAM; 16 GiB is the minimum for Ghidra + JADX side by side (see docs/sizing.md)"
disk_gb=$(df -Pk "$HERE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
[ "$disk_gb" -ge 60 ] || warn "only ${disk_gb} GiB free under $HERE; samples and decompiled trees add up quickly"

install_custom_cert() {
  mkdir -p config/tls
  install -m 0644 "$CERT" config/tls/fullchain.pem
  install -m 0600 "$KEY" config/tls/privkey.pem
}

# ---- 2. .env ---------------------------------------------------------------
if [ -f .env ] && [ "$FORCE" -ne 1 ]; then
  info "existing .env found; keeping its secrets"
  mode="$(sed -n 's/^INSTALL_MODE=//p' .env | tail -1)"; mode="${mode:-domain}"
  [ -z "$DOMAIN" ] || [ "$mode" = domain ] || die "this install is reached by IP address; switching to --domain needs a fresh install (--force regenerates secrets)"
  [ -z "$IP" ] || [ "$mode" = ip ] || die "this install uses DNS names; switching to --ip needs a fresh install (--force regenerates secrets)"
  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$(sed -n 's/^OPENBIN_DOMAIN=//p' .env | tail -1)" ]; then
    die "changing the base domain of an existing install is not supported; edit .env by hand or reinstall"
  fi
  # Flags given on a re-run update the stored value; everything else stays.
  [ -z "$IP" ]               || set_env HOST_IP "$IP"
  [ -z "$OPENBIN_PORT_ARG" ] || set_env OPENBIN_PORT "$OPENBIN_PORT_ARG"
  [ -z "$OPENAPK_PORT_ARG" ] || set_env OPENAPK_PORT "$OPENAPK_PORT_ARG"
  [ -z "$HTTP_PORT_ARG" ]    || set_env HTTP_PORT "$HTTP_PORT_ARG"
  [ -z "$HTTPS_PORT_ARG" ]   || set_env HTTPS_PORT "$HTTPS_PORT_ARG"
  [ -z "$EXTRA_SANS" ]       || set_env TLS_EXTRA_SANS "$EXTRA_SANS"
  [ -z "$LLM_ALLOW" ]        || set_env LLM_EGRESS_ALLOWLIST "$LLM_ALLOW"
  [ -z "$SELF_REG" ]         || set_env SELF_REGISTRATION "$SELF_REG"
  if [ -n "$CERT" ]; then install_custom_cert; set_env TLS_MODE custom; fi
  # A newer bundle carries its own version; adopt it.
  if [ -n "$VERSION_OVERRIDE" ]; then set_env OPENBIN_VERSION "$VERSION_OVERRIDE"
  elif [ -n "$IMAGES" ]; then set_env OPENBIN_VERSION "$(cat VERSION)"; fi
  load_env
else
  # New secrets cannot open a database that an earlier install created.
  vol="${COMPOSE_PROJECT_NAME:-openbin}_postgres-data"
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    die "data from an earlier install exists on this host (Docker volume $vol) but its .env is missing here.
       To keep that data: put the old .env (or a backup's env.backup) at $HERE/.env and run this again.
       To start clean and DELETE that data:
         docker ps -aq --filter label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-openbin} | xargs -r docker rm -f
         docker volume ls -q --filter label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-openbin} | xargs -r docker volume rm"
  fi
  if [ -n "$DOMAIN" ]; then
    # -- DNS names ------------------------------------------------------------
    DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*$##')"
    [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || die "'$DOMAIN' is not a hostname"
    [ -n "$ADMIN_EMAIL_ARG" ] || die "--admin-email is required with --domain"
    TLS_MODE="${TLS_MODE_ARG:-internal}"
    [ -z "$CERT" ] || TLS_MODE=custom
    case "$TLS_MODE" in
      internal) ;;
      acme) [ -n "$ACME_EMAIL" ] || die "--acme-email is required for --tls acme" ;;
      custom) [ -n "$CERT" ] || die "--cert/--key are required for --tls custom"; install_custom_cert ;;
      *) die "--tls must be internal, acme or custom" ;;
    esac
    layout="INSTALL_MODE=domain
OPENBIN_DOMAIN=$DOMAIN
APP_HOST=app.$DOMAIN
APK_HOST=apk.$DOMAIN
API_HOST=api.$DOMAIN
AUTH_HOST=auth.$DOMAIN
S3_HOST=s3.$DOMAIN
HTTP_PORT=${HTTP_PORT_ARG:-80}
HTTPS_PORT=${HTTPS_PORT_ARG:-443}"
    admin_email="$ADMIN_EMAIL_ARG"; admin_pw=""; self_reg="${SELF_REG:-false}"
  else
    # -- IP address -----------------------------------------------------------
    [ -n "$IP" ] || IP="$(detect_ip)"
    [ -n "$IP" ] || die "could not work out this host's address; pass --ip ADDR"
    [[ "$IP" =~ ^[A-Za-z0-9.-]+$ ]] || die "'$IP' is not an IPv4 address or hostname"
    case "${TLS_MODE_ARG:-}" in
      ""|selfsigned|custom) ;;
      *) die "--tls $TLS_MODE_ARG needs DNS names (--domain); by IP the installer issues its own certificate, or takes yours with --cert/--key" ;;
    esac
    if [ -n "$CERT" ]; then TLS_MODE=custom; install_custom_cert
    else [ "${TLS_MODE_ARG:-}" != custom ] || die "--cert/--key are required for --tls custom"; TLS_MODE=selfsigned; fi
    layout="INSTALL_MODE=ip
HOST_IP=$IP
OPENBIN_PORT=${OPENBIN_PORT_ARG:-443}
OPENAPK_PORT=${OPENAPK_PORT_ARG:-8443}
TLS_EXTRA_SANS=$EXTRA_SANS"
    admin_email="${ADMIN_EMAIL_ARG:-admin@openbin.local}"; admin_pw="$(random_token 16)"
    # A team should be able to start without an administrator creating
    # every account. With a directory given, people come from there instead.
    if [ -n "$LDAP_URL" ]; then self_reg="${SELF_REG:-false}"; else self_reg="${SELF_REG:-true}"; fi
  fi
  [[ "$admin_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die "'$admin_email' is not an email address"

  info "writing .env"
  ( umask 077; cat > .env <<ENV
# OpenBin Enterprise — generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by install.sh
# See .env.example for what each value does. chmod 600; contains secrets.
OPENBIN_VERSION=${VERSION_OVERRIDE:-$(cat VERSION)}
IMAGE_PREFIX=ghcr.io/openbin-ai/enterprise

$layout

TLS_MODE=$TLS_MODE
ACME_EMAIL=$ACME_EMAIL

ADMIN_EMAIL=$admin_email
ADMIN_INITIAL_PASSWORD=$admin_pw
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$(random_token 20)

SELF_REGISTRATION=$self_reg
TOS_REQUIRED=false
LLM_EGRESS_ALLOWLIST=$LLM_ALLOW

POSTGRES_PASSWORD=$(random_token 32)
KEYCLOAK_DB_PASSWORD=$(random_token 32)
MINIO_ROOT_USER=openbin
MINIO_ROOT_PASSWORD=$(random_token 32)
OPENAPK_KEK_B64=$(random_key_b64)
JADX_WORKER_TOKEN=$(random_token 32)
KEYCLOAK_CORE_CLIENT_SECRET=$(random_token 32)

CORE_MEM=3g
GHIDRA_MEM=8g
JADX_MEM=6g
ENV
  )
  chmod 600 .env
  load_env
fi

if [ "$INSTALL_MODE" = ip ]; then
  info "this install will be reached at ${APP_URL}/ (OpenBin) and ${APK_URL}/ (OpenAPK)"
  ports="$OPENBIN_PORT $OPENAPK_PORT"
else
  ports="${HTTP_PORT:-80} ${HTTPS_PORT:-443}"
fi
# Ports held by our own proxy (a re-run) are fine; anything else is a conflict.
if [ "$NO_START" -ne 1 ] && [ -z "$(compose ps -q proxy 2>/dev/null || true)" ]; then
  for p in $ports; do
    if port_in_use "$p"; then
      if [ "$INSTALL_MODE" = ip ]; then die "port $p is already in use on this host; choose others with --openbin-port / --openapk-port"
      else die "port $p is already in use on this host; stop the other web server or pass --http-port/--https-port"; fi
    fi
  done
fi

# ---- 3. images -------------------------------------------------------------
if [ "$NO_START" -ne 1 ]; then
  if [ -n "$IMAGES" ]; then
    info "loading images from $IMAGES (this takes a few minutes)"
    load_images "$IMAGES"
  elif images_present; then
    info "images for ${OPENBIN_VERSION} are already on this host"
  else
    if [ -n "$REGISTRY_TOKEN" ]; then
      info "logging in to ghcr.io"
      echo "$REGISTRY_TOKEN" | docker login ghcr.io -u "${REGISTRY_USER:-openbin-customer}" --password-stdin
    fi
    info "pulling images for ${OPENBIN_VERSION} (needs access to ghcr.io/openbin-ai/enterprise)"
    compose pull
  fi
fi

# ---- 4. render -------------------------------------------------------------
render_all
if [ "$NO_START" -eq 1 ]; then
  info "--no-start: configuration written, nothing pulled or started."
  print_summary; exit 0
fi

# ---- 5. start --------------------------------------------------------------
info "starting the stack"
start_stack 600
if [ -n "$LDAP_URL" ]; then
  [ -z "$LDAP_CA" ] || ldap_trust_ca "$LDAP_CA"
  ldap_connect "$LDAP_URL" "$LDAP_BIND_DN" "$LDAP_PW" "$LDAP_USERS_DN" "$LDAP_VENDOR" "$LDAP_USER_ATTR" "$LDAP_FILTER"
fi

# ---- 6. summary ------------------------------------------------------------
print_summary
