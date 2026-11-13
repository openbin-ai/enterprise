#!/usr/bin/env bash
# Shared helpers for install.sh and bin/openbin-enterprise. Sourced, not run.

C_INFO=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OK=$'\033[32m'; C_0=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C_INFO" "$C_0" "$*"; }
ok()   { printf '%s==>%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }
banner() { printf '\n%s\n%s\n\n' "$*" "$(printf '%*s' "${#1}" '' | tr ' ' '=')"; }

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Docker with Compose v2 is the only thing the host has to provide.
require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed (https://docs.docker.com/engine/install/)"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running? are you in the docker group, or do you need sudo?)"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required ('docker compose', not 'docker-compose')"
}

compose() { (cd "$ROOT" && docker compose --env-file .env "$@"); }

# ---- .env ---------------------------------------------------------------------
load_env() {
  [ -f "$ROOT/.env" ] || die "no .env in $ROOT; run ./install.sh first"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
  derive_urls
}

# Set (or add) one KEY=VALUE line in .env, keeping the file's permissions.
set_env() {
  local k="$1" v="$2" f="$ROOT/.env" t
  t="$(mktemp)"
  grep -v "^$k=" "$f" > "$t" || true
  printf '%s=%s\n' "$k" "$v" >> "$t"
  cat "$t" > "$f"; rm -f "$t"
}

port_suffix() { [ "$1" = 443 ] || printf ':%s' "$1"; }

# Every public URL comes from here, so the proxy, the realm, the backend and
# the web apps can never disagree. Two layouts:
#
#   ip      one address, no DNS. OpenBin and OpenAPK each get a port; the API
#           (/api), sign-in (/auth) and object storage (bucket paths) are
#           routed under those same two origins, so two ports is all a
#           firewall has to allow.
#   domain  five hostnames under one base domain on a single HTTPS port.
#
# The values are derived on every run instead of stored, which is why the
# stack must be driven through bin/openbin-enterprise (or `compose` here)
# rather than a bare `docker compose`.
derive_urls() {
  : "${INSTALL_MODE:=domain}"
  case "$INSTALL_MODE" in
    ip)
      [ -n "${HOST_IP:-}" ] || die "HOST_IP is empty in .env"
      : "${OPENBIN_PORT:=443}" "${OPENAPK_PORT:=8443}"
      [ "$OPENBIN_PORT" != "$OPENAPK_PORT" ] || die "OPENBIN_PORT and OPENAPK_PORT must differ (both are $OPENBIN_PORT)"
      APP_URL="https://${HOST_IP}$(port_suffix "$OPENBIN_PORT")"
      APK_URL="https://${HOST_IP}$(port_suffix "$OPENAPK_PORT")"
      # Each web app talks to the backend and discovers sign-in through its
      # own origin, so one accepted certificate warning per app is enough.
      # Sign-in itself always happens on the OpenBin origin (one issuer).
      API_URL="$APP_URL";        APK_API_URL="$APK_URL"
      AUTH_URL="$APP_URL/auth";  APK_AUTH_URL="$APK_URL/auth"
      S3_URL="$APP_URL"
      KC_PATH="/auth"
      COMPOSE_FILE="compose.yaml:compose.ip.yaml" ;;
    domain)
      local sfx; sfx="$(port_suffix "${HTTPS_PORT:-443}")"
      APP_URL="https://${APP_HOST}${sfx}";   APK_URL="https://${APK_HOST}${sfx}"
      API_URL="https://${API_HOST}${sfx}";   APK_API_URL="$API_URL"
      AUTH_URL="https://${AUTH_HOST}${sfx}"; APK_AUTH_URL="$AUTH_URL"
      S3_URL="https://${S3_HOST}${sfx}"
      KC_PATH=""
      COMPOSE_FILE="compose.yaml:compose.domain.yaml" ;;
    *) die "INSTALL_MODE must be ip or domain (got '$INSTALL_MODE')" ;;
  esac
  export INSTALL_MODE OPENBIN_PORT OPENAPK_PORT COMPOSE_FILE KC_PATH \
         APP_URL APK_URL API_URL APK_API_URL AUTH_URL APK_AUTH_URL S3_URL
}

random_token() {
  # URL-safe, no characters that would need quoting in .env. Reads the
  # kernel directly so the host needs no openssl.
  head -c 96 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-"${1:-32}"
}
random_key_b64() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }

port_in_use() {
  if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
  else (echo >"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; fi
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# The address other machines use to reach this host. Works without a
# default route (air-gapped networks often have none).
detect_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)" || true
  if [ -z "$ip" ]; then
    ip="$(ip -4 -o addr show scope global 2>/dev/null \
          | awk '$2 !~ /^(docker|br-|veth|virbr|cni|flannel|podman|tailscale)/ {sub(/\/.*/,"",$4); print $4; exit}')" || true
  fi
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  printf '%s' "$ip"
}

# ---- TLS for IP mode -----------------------------------------------------------
# openssl from the host when it has one, otherwise from the backend image
# (already loaded by then), so the host still needs nothing but Docker.
_openssl() {
  local dir="$ROOT/config/tls"
  if command -v openssl >/dev/null 2>&1; then (cd "$dir" && openssl "$@")
  else
    docker run --rm --network none -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$dir:/w" -w /w \
      --entrypoint openssl "${IMAGE_PREFIX}/core:${OPENBIN_VERSION}" "$@"
  fi
}

# This install's own CA plus a server certificate for HOST_IP. The CA is
# created once and never replaced, so a CA that analysts imported keeps
# working when the certificate is re-issued (new address, or near expiry).
ensure_selfsigned_cert() {
  local dir="$ROOT/config/tls" sans san
  mkdir -p "$dir"
  if is_ipv4 "$HOST_IP"; then sans="IP:${HOST_IP}"; else sans="DNS:${HOST_IP}"; fi
  sans="$sans,IP:127.0.0.1,DNS:localhost"
  for san in $(printf '%s' "${TLS_EXTRA_SANS:-}" | tr ',' ' '); do
    if is_ipv4 "$san"; then sans="$sans,IP:$san"; else sans="$sans,DNS:$san"; fi
  done
  if [ -f "$dir/fullchain.pem" ] && [ -f "$dir/privkey.pem" ] && [ -f "$dir/ca.pem" ] \
     && [ "$(cat "$dir/.sans" 2>/dev/null)" = "$sans" ] \
     && _openssl x509 -checkend 2592000 -noout -in fullchain.pem >/dev/null 2>&1; then
    return 0
  fi
  info "issuing a TLS certificate for ${HOST_IP}"
  if [ ! -f "$dir/ca.key" ] || [ ! -f "$dir/ca.pem" ]; then
    cat > "$dir/ca.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
O = OpenBin Enterprise
CN = OpenBin Enterprise CA (${HOST_IP})
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
CNF
    _openssl genrsa -out ca.key 4096 >/dev/null 2>&1 || die "could not create the CA key (openssl failed)"
    _openssl req -x509 -new -key ca.key -sha256 -days 3650 -config ca.cnf -out ca.pem \
      || die "could not create the CA certificate"
  fi
  cat > "$dir/leaf.ext" <<EXT
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${sans}
authorityKeyIdentifier = keyid
EXT
  _openssl genrsa -out privkey.pem 2048 >/dev/null 2>&1 || die "could not create the server key"
  _openssl req -new -key privkey.pem -subj "/O=OpenBin Enterprise/CN=${HOST_IP}" -out leaf.csr \
    || die "could not create the certificate request"
  # 825 days: the longest lifetime every browser accepts from a private CA.
  _openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 -sha256 \
    -extfile leaf.ext -out leaf.pem >/dev/null 2>&1 || die "could not sign the server certificate"
  cat "$dir/leaf.pem" "$dir/ca.pem" > "$dir/fullchain.pem"
  printf '%s' "$sans" > "$dir/.sans"
  rm -f "$dir/leaf.csr" "$dir/leaf.pem" "$dir/leaf.ext" "$dir/ca.cnf"
  # The proxy runs as root in its container, so the keys can stay private.
  chmod 600 "$dir/ca.key" "$dir/privkey.pem"; chmod 644 "$dir/fullchain.pem" "$dir/ca.pem"
  # Analysts fetch the CA from the instance itself: <OpenBin URL>/downloads/openbin-ca.crt
  mkdir -p "$ROOT/downloads"; cp "$dir/ca.pem" "$ROOT/downloads/openbin-ca.crt"
}

# ---- rendering ---------------------------------------------------------------
_caddy_site_snippet() { # $1 = tls line
  cat <<CADDY
(site) {
$1
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
}

(api) {
	request_body {
		max_size 1GB
	}
	reverse_proxy core:8081 {
		# Streaming answers (SSE) and long decompiles.
		flush_interval -1
		transport http {
			read_timeout 30m
			write_timeout 30m
		}
	}
}

(s3) {
	request_body {
		max_size 4GB
	}
	reverse_proxy minio:9000 {
		transport http {
			read_timeout 1h
			write_timeout 1h
		}
	}
}
CADDY
}

render_caddyfile_ip() {
  local tls_line="	tls /etc/openbin/tls/fullchain.pem /etc/openbin/tls/privkey.pem"
  {
    cat <<CADDY
# Generated from .env by bin/openbin-enterprise render. Do not hand-edit.
# IP mode: two ports, everything else is routed by path under them.
{
	admin off
	# Only the two app ports are published; there is no :80 to redirect from.
	auto_https disable_redirects
	# Browsers send no server name when the URL is an IP address.
	default_sni ${HOST_IP}
	fallback_sni ${HOST_IP}
}

CADDY
    _caddy_site_snippet "$tls_line"
    cat <<CADDY

(routes) {
	@api path /api/*
	handle @api {
		import api
	}
	@auth path ${KC_PATH} ${KC_PATH}/*
	handle @auth {
		reverse_proxy keycloak:8080
	}
	# Presigned upload/download URLs: /<bucket>/<key>, signed for this host.
	@s3 path /openbin-media /openbin-media/* /openbin-analysis /openbin-analysis/*
	handle @s3 {
		import s3
	}
}

# OpenBin (native binaries, scripts)
https://:${OPENBIN_PORT} {
	import site
	import routes
	handle {
		reverse_proxy frontend:8080
	}
}

# OpenAPK (Android)
https://:${OPENAPK_PORT} {
	import site
	import routes
	handle {
		reverse_proxy frontend:8081
	}
}
CADDY
  } > "$ROOT/config/Caddyfile"
}

render_caddyfile_domain() {
  local tls_block
  case "${TLS_MODE:-internal}" in
    internal) tls_block="	tls internal" ;;
    acme)     tls_block="" ;;
    custom)   tls_block="	tls /etc/openbin/tls/fullchain.pem /etc/openbin/tls/privkey.pem" ;;
    *) die "TLS_MODE must be internal, acme or custom in domain mode (got '${TLS_MODE}')" ;;
  esac
  local global=""
  if [ "${TLS_MODE:-internal}" = acme ]; then
    [ -n "${ACME_EMAIL:-}" ] || die "ACME_EMAIL is required when TLS_MODE=acme"
    global="	email ${ACME_EMAIL}"
  fi
  {
    cat <<CADDY
# Generated from .env by bin/openbin-enterprise render. Do not hand-edit.
{
	admin off
${global}
}

CADDY
    _caddy_site_snippet "$tls_block"
    cat <<CADDY

https://${APP_HOST} {
	import site
	reverse_proxy frontend:8080
}

https://${APK_HOST} {
	import site
	reverse_proxy frontend:8081
}

https://${API_HOST} {
	import site
	import api
}

https://${AUTH_HOST} {
	import site
	reverse_proxy keycloak:8080
}

https://${S3_HOST} {
	import site
	import s3
}
CADDY
  } > "$ROOT/config/Caddyfile"
}

render_caddyfile() {
  # Docker creates a missing bind-mount source as an empty directory; that
  # happens if a container was started before the first render.
  if [ -d "$ROOT/config/Caddyfile" ]; then
    rmdir "$ROOT/config/Caddyfile" 2>/dev/null || die "$ROOT/config/Caddyfile is a directory; remove it and run this again"
  fi
  if [ "$INSTALL_MODE" = ip ]; then render_caddyfile_ip; else render_caddyfile_domain; fi
}

render_realm() {
  local reg="${SELF_REGISTRATION:-false}" admin=""
  [ "$reg" = true ] || reg=false
  # First administrator, created with the realm on first boot. The password
  # is temporary: Keycloak makes them choose a new one at first sign-in.
  if [ -n "${ADMIN_INITIAL_PASSWORD:-}" ]; then
    admin=",{\"username\":\"${ADMIN_EMAIL}\",\"email\":\"${ADMIN_EMAIL}\",\"emailVerified\":true,\"enabled\":true,\"firstName\":\"OpenBin\",\"lastName\":\"Admin\",\"credentials\":[{\"type\":\"password\",\"value\":\"${ADMIN_INITIAL_PASSWORD}\",\"temporary\":true}],\"requiredActions\":[\"UPDATE_PASSWORD\"]}"
  fi
  mkdir -p "$ROOT/config/keycloak/import"
  # No rendered realm yet means Keycloak will import this one as written.
  [ -f "$ROOT/config/keycloak/import/realm-openapk.json" ] || REALM_FRESH=1
  sed -e "s#__APP_ORIGIN__#${APP_URL}#g" \
      -e "s#__APK_ORIGIN__#${APK_URL}#g" \
      -e "s#__REGISTRATION_ALLOWED__#${reg}#g" \
      -e "s#__CORE_CLIENT_SECRET__#${KEYCLOAK_CORE_CLIENT_SECRET}#g" \
      -e "s#__ADMIN_USER__#${admin}#g" \
      "$ROOT/config/keycloak/realm.tmpl.json" > "$ROOT/config/keycloak/import/realm-openapk.json"
  # Holds a client secret and the first password, so keep it private, but
  # Keycloak reads it as uid 1000 inside its container, whoever installs.
  local f="$ROOT/config/keycloak/import/realm-openapk.json"
  if [ "$(id -u)" -eq 1000 ]; then chmod 600 "$f"
  elif chown 1000:0 "$f" 2>/dev/null; then chmod 600 "$f"
  else chmod 644 "$f"; fi
}

_proxy_inputs_sum() { { cat "$ROOT/config/Caddyfile" "$ROOT"/config/tls/*.pem 2>/dev/null || true; } | cksum; }

render_all() {
  info "rendering proxy and sign-in configuration for ${APP_URL}"
  local before; before="$(_proxy_inputs_sum)"
  if [ "${TLS_MODE:-internal}" = selfsigned ]; then ensure_selfsigned_cert; fi
  render_caddyfile
  render_realm
  # The proxy reads its config and certificate once, at start.
  [ "$before" = "$(_proxy_inputs_sum)" ] || PROXY_DIRTY=1
}

# Bring the stack to the rendered state. Compose recreates containers whose
# environment or ports changed; a proxy that only got a new config file or
# certificate has to be restarted by hand.
start_stack() {
  local running; running="$(compose ps -q proxy 2>/dev/null || true)"
  compose up -d --remove-orphans
  if [ -n "$running" ] && [ "${PROXY_DIRTY:-0}" = 1 ] && [ "$running" = "$(compose ps -q proxy 2>/dev/null || true)" ]; then
    compose restart proxy
  fi
  wait_for_core "${1:-600}"
  wait_for_signin 300
  sync_realm_urls
  sync_realm_settings
}

# Keycloak imports the realm file only once, on first boot. Afterwards the
# two web clients (one per app, each allowed exactly its own origin) are
# kept in step with .env here: created if an older realm lacks one, updated
# when the address or ports change. Without this, sign-in is refused.
REALM_CLIENTS_REV=2
sync_realm_urls() {
  local marker="$ROOT/config/.public-urls" want="v${REALM_CLIENTS_REV} ${APP_URL} ${APK_URL}"
  if [ ! -f "$marker" ] && [ "${REALM_FRESH:-0}" = 1 ]; then printf '%s' "$want" > "$marker"; return 0; fi
  [ "$(cat "$marker" 2>/dev/null)" != "$want" ] || return 0
  info "updating the sign-in clients for ${APP_URL} and ${APK_URL}"
  local cfg=/tmp/kcadm.config i=0
  local manual="Sign in at ${AUTH_URL}/admin/, realm 'openapk', and make sure client 'openbin-frontend' allows ${APP_URL}/* and client 'openapk-frontend' allows ${APK_URL}/* (redirect URIs and web origins)."
  kc() { compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@" --config "$cfg"; }
  until kc config credentials --server "http://localhost:8080${KC_PATH}" --realm openapk \
          --client openbin-core --secret "$KEYCLOAK_CORE_CLIENT_SECRET" >/dev/null 2>&1; do
    i=$((i+1))
    if [ "$i" -ge 36 ]; then warn "could not reach Keycloak to update the sign-in clients. $manual"; return 0; fi
    sleep 5
  done
  ensure_client() { # clientId name origin
    local id
    id="$(kc get clients -r openapk -q "clientId=$1" --fields id --format csv --noquotes 2>/dev/null | tr -d '\r\n')"
    if [ -n "$id" ]; then
      kc update "clients/$id" -r openapk \
        -s "redirectUris=[\"$3/*\"]" -s "webOrigins=[\"$3\"]" \
        -s "attributes.\"post.logout.redirect.uris\"=$3/*" >/dev/null 2>&1
    else
      kc create clients -r openapk -s "clientId=$1" -s "name=$2" -s enabled=true \
        -s publicClient=true -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
        -s protocol=openid-connect \
        -s "redirectUris=[\"$3/*\"]" -s "webOrigins=[\"$3\"]" \
        -s 'attributes."pkce.code.challenge.method"=S256' \
        -s "attributes.\"post.logout.redirect.uris\"=$3/*" >/dev/null 2>&1
    fi
  }
  if ensure_client openbin-frontend "OpenBin web app" "$APP_URL" \
     && ensure_client openapk-frontend "OpenAPK web app" "$APK_URL"; then
    printf '%s' "$want" > "$marker"
    ok "sign-in clients ready"
  else
    warn "could not update the sign-in clients automatically. $manual"
  fi
}

# ---- accounts: self-registration and LDAP ---------------------------------------
# Realm-level changes after first boot go through Keycloak's own admin
# account (KEYCLOAK_ADMIN_* in .env), from inside the Keycloak container.
KCA_CFG=/tmp/kcadm-admin.config
kca() { compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@" --config "$KCA_CFG"; }
kc_admin_login() { # [attempts]
  local i=0
  until kca config credentials --server "http://localhost:8080${KC_PATH}" --realm master \
          --user "${KEYCLOAK_ADMIN_USER:-admin}" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 </dev/null; do
    i=$((i+1)); [ "$i" -lt "${1:-12}" ] || return 1
    sleep 5
  done
}
_kc_admin_hint="Keycloak's admin sign-in failed (was the '${KEYCLOAK_ADMIN_USER:-admin}' account changed or removed? keep KEYCLOAK_ADMIN_PASSWORD in .env current)."

# SELF_REGISTRATION in .env -> the "Register" link on the sign-in page.
sync_realm_settings() {
  local marker="$ROOT/config/.realm-settings" reg="${SELF_REGISTRATION:-false}"
  [ "$reg" = true ] || reg=false
  local want="registration=$reg"
  if [ ! -f "$marker" ] && [ "${REALM_FRESH:-0}" = 1 ]; then printf '%s' "$want" > "$marker"; return 0; fi
  [ "$(cat "$marker" 2>/dev/null)" != "$want" ] || return 0
  if ! kc_admin_login; then
    warn "could not change self-registration. $_kc_admin_hint Or set it by hand: ${AUTH_URL}/admin/ > realm openapk > Realm settings > Login > User registration."
    return 0
  fi
  if kca update realms/openapk -s "registrationAllowed=$reg" >/dev/null 2>&1 </dev/null; then
    printf '%s' "$want" > "$marker"
    if [ "$reg" = true ]; then ok "self-registration is on: people create their own accounts from the sign-in page"
    else ok "self-registration is off: accounts come from an administrator or your directory"; fi
  else
    warn "could not change self-registration in Keycloak"
  fi
}

json_str() { # JSON string literal for $1
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

ldap_component_id() {
  kca get components -r openapk -q name=ldap -q type=org.keycloak.storage.UserStorageProvider \
      --fields id --format csv --noquotes 2>/dev/null </dev/null | tr -d '\r' | head -1
}

# Connect the sign-in page to an LDAP directory or Active Directory.
# Read-only: people sign in with their directory password, their profile is
# copied in on first sign-in (and by `ldap sync`), nothing is written back.
# The bind password goes to Keycloak over stdin and is stored only there.
#   ldap_connect URL BIND_DN BIND_PASSWORD USERS_DN VENDOR USERNAME_ATTR FILTER
ldap_connect() {
  local url="$1" bind_dn="$2" bind_pw="$3" users_dn="$4" vendor="${5:-other}" user_attr="${6:-}" filter="${7:-}"
  local uuid_attr classes
  case "$vendor" in
    ad) uuid_attr=objectGUID; classes="person, organizationalPerson, user"; : "${user_attr:=sAMAccountName}" ;;
    other) uuid_attr=entryUUID; classes="inetOrgPerson, organizationalPerson"; : "${user_attr:=uid}" ;;
    *) die "--vendor must be 'ad' (Active Directory) or 'other' (OpenLDAP, 389-DS, FreeIPA, ...)" ;;
  esac
  [[ "$url" =~ ^ldaps?://[^[:space:]]+$ ]] || die "--url must look like ldap://host:389 or ldaps://host:636"
  kc_admin_login || die "$_kc_admin_hint"

  info "checking the connection to $url"
  local out
  if ! out="$(printf '{"action":"testAuthentication","connectionUrl":%s,"authType":"simple","bindDn":%s,"bindCredential":%s,"useTruststoreSpi":"always","connectionTimeout":"10000"}' \
        "$(json_str "$url")" "$(json_str "$bind_dn")" "$(json_str "$bind_pw")" \
        | kca create testLDAPConnection -r openapk -f - 2>&1)"; then
    printf '%s\n' "$out" | tail -3 >&2
    case "$url" in ldaps://*) warn "for ldaps:// with a private CA, pass the CA with --ca-cert FILE" ;; esac
    die "could not sign in to the directory as '$bind_dn'. Check the URL (reachable from this host?), the bind DN and its password."
  fi
  ok "directory reachable, bind account accepted"

  local realm_id id body
  realm_id="$(kca get realms/openapk --fields id --format csv --noquotes 2>/dev/null </dev/null | tr -d '\r\n')"
  id="$(ldap_component_id)"
  local id_line=""
  [ -z "$id" ] || id_line="\"id\": $(json_str "$id"),"
  body="$(cat <<JSON
{
  ${id_line}
  "name": "ldap",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "parentId": $(json_str "$realm_id"),
  "config": {
    "enabled": ["true"],
    "priority": ["0"],
    "vendor": [$(json_str "$vendor")],
    "connectionUrl": [$(json_str "$url")],
    "authType": ["simple"],
    "bindDn": [$(json_str "$bind_dn")],
    "bindCredential": [$(json_str "$bind_pw")],
    "usersDn": [$(json_str "$users_dn")],
    "searchScope": ["2"],
    "customUserSearchFilter": [$(json_str "$filter")],
    "usernameLDAPAttribute": [$(json_str "$user_attr")],
    "rdnLDAPAttribute": [$(json_str "$( [ "$vendor" = ad ] && echo cn || echo "$user_attr" )")],
    "uuidLDAPAttribute": ["$uuid_attr"],
    "userObjectClasses": ["$classes"],
    "editMode": ["READ_ONLY"],
    "importEnabled": ["true"],
    "syncRegistrations": ["false"],
    "trustEmail": ["true"],
    "pagination": ["true"],
    "useTruststoreSpi": ["always"],
    "connectionPooling": ["true"],
    "cachePolicy": ["DEFAULT"],
    "fullSyncPeriod": ["86400"],
    "changedSyncPeriod": ["3600"]
  }
}
JSON
)"
  if [ -n "$id" ]; then
    printf '%s' "$body" | kca update "components/$id" -r openapk -f - >/dev/null 2>&1 || die "Keycloak rejected the LDAP settings"
    ok "LDAP connection updated"
  else
    printf '%s' "$body" | kca create components -r openapk -f - >/dev/null 2>&1 || die "Keycloak rejected the LDAP settings"
    ok "LDAP connected"
  fi
  # Keycloak's default for non-AD directories fills "first name" from cn
  # (the full name), which shows people as "Jane Doe Doe".
  if [ "$vendor" = other ]; then
    local ldap_id mid
    ldap_id="$(ldap_component_id)"
    mid="$(kca get components -r openapk -q "parent=$ldap_id" -q "name=first name" \
             --fields id --format csv --noquotes 2>/dev/null </dev/null | tr -d '\r' | head -1)"
    [ -z "$mid" ] || kca update "components/$mid" -r openapk -s 'config."ldap.attribute"=["givenName"]' >/dev/null 2>&1 </dev/null || true
  fi
  ldap_sync
  cat <<NOTE

People in ${users_dn} can now sign in at ${APP_URL}/ with their directory
username (${user_attr}) or email, and their directory password.
  - Each person needs an email address ('mail') in the directory.
  - The directory is re-read every hour; 'bin/openbin-enterprise ldap sync' does it now.
  - Local sign-up is $( [ "${SELF_REGISTRATION:-false}" = true ] && echo "still ON. Turn it off with: ./install.sh --no-self-registration" || echo "off" ).
NOTE
}

ldap_sync() {
  local id; kc_admin_login 2 || die "$_kc_admin_hint"
  id="$(ldap_component_id)"; [ -n "$id" ] || die "no LDAP connection is configured (bin/openbin-enterprise ldap connect ...)"
  info "reading users from the directory"
  local out
  out="$(kca create "user-storage/$id/sync?action=triggerFullSync" -r openapk -o 2>/dev/null </dev/null \
         | grep -oE '"(added|updated|removed|failed)" *: *[0-9]+' | tr -d '" ' | sed 's/:/ /' \
         | awk '{printf "%s%s %s", (NR>1?", ":""), $2, $1}')" || true
  echo "    ${out:-no summary returned}"
}

ldap_status() {
  local id; kc_admin_login 2 || die "$_kc_admin_hint"
  id="$(ldap_component_id)"
  if [ -z "$id" ]; then echo "LDAP: not connected"; return 0; fi
  echo "LDAP: connected"
  kca get "components/$id" -r openapk 2>/dev/null </dev/null \
    | grep -E '"(connectionUrl|bindDn|usersDn|vendor|usernameLDAPAttribute|customUserSearchFilter)"' | tr -d '[]"' | sed 's/ *, *$//; s/^ */  /'
}

ldap_remove() {
  local id; kc_admin_login 2 || die "$_kc_admin_hint"
  id="$(ldap_component_id)"; [ -n "$id" ] || { echo "LDAP: not connected"; return 0; }
  kca delete "components/$id" -r openapk </dev/null || die "could not remove the LDAP connection"
  ok "LDAP disconnected; accounts that came from the directory were removed (their projects stay in the database)"
}

# Let Keycloak trust the CA that signed the directory's ldaps:// certificate.
ldap_trust_ca() {
  [ -f "$1" ] || die "CA certificate not found: $1"
  grep -q 'BEGIN CERTIFICATE' "$1" || die "$1 is not a PEM certificate"
  mkdir -p "$ROOT/config/keycloak/truststores"
  install -m 0644 "$1" "$ROOT/config/keycloak/truststores/ldap-ca.pem"
  info "restarting sign-in so it trusts the directory's CA"
  compose up -d keycloak >/dev/null 2>&1
  compose restart keycloak >/dev/null 2>&1
  wait_for_signin 300
}

# ---- images ------------------------------------------------------------------
load_images() {
  case "$1" in
    *.zst) zstd -dc "$1" | docker load ;;
    *.gz)  gzip -dc "$1" | docker load ;;
    *)     docker load -i "$1" ;;
  esac
}

# Every image the stack runs, resolved from the current .env.
image_list() {
  compose config --images 2>/dev/null | sort -u
}

# True when every image the stack needs is already on this host, so nothing
# has to be pulled (the normal case for re-runs inside an air gap).
images_present() {
  local img list
  list="$(image_list)"; [ -n "$list" ] || return 1
  for img in $list; do docker image inspect "$img" >/dev/null 2>&1 || return 1; done
}

# ---- health ------------------------------------------------------------------
wait_for_core() {
  local deadline=$(( $(date +%s) + ${1:-600} ))
  info "waiting for the backend to become healthy (first boot runs database migrations)"
  while :; do
    local cid status
    cid="$(compose ps -q core 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)"
      case "$status" in
        healthy) echo; ok "backend healthy"; return 0 ;;
        exited|dead) compose logs --tail 60 core; die "backend exited during startup; see the log above" ;;
      esac
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { compose logs --tail 60 core; die "backend not healthy after ${1:-600}s"; }
    printf '.'; sleep 5
  done
}

# The backend can be healthy while Keycloak is still importing the realm,
# or failing to. Nobody can sign in until this answers, so do not report
# success before it does.
wait_for_signin() {
  local deadline=$(( $(date +%s) + ${1:-300} ))
  info "waiting for sign-in to come up"
  until compose exec -T proxy wget -qO /dev/null \
          "http://keycloak:8080${KC_PATH}/realms/openapk/.well-known/openid-configuration" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      compose logs --tail 40 keycloak
      die "sign-in (Keycloak) did not come up after ${1:-300}s; see the log above"
    fi
    printf '.'; sleep 5
  done
  echo; ok "sign-in ready"
}

print_summary() {
  if [ "$INSTALL_MODE" = ip ]; then print_summary_ip; else print_summary_domain; fi
  cat <<SUMMARY

Day two: bin/openbin-enterprise status | logs | backup | upgrade | ca-cert
SUMMARY
}

print_summary_ip() {
  cat <<SUMMARY

${C_OK}OpenBin Enterprise is configured.${C_0}

  OpenBin (native binaries, scripts)   ${APP_URL}/
  OpenAPK (Android)                    ${APK_URL}/
  CLI + BINNY downloads                ${APP_URL}/downloads/
  User admin (Keycloak)                ${AUTH_URL}/admin/   user: ${KEYCLOAK_ADMIN_USER:-admin}  password: KEYCLOAK_ADMIN_PASSWORD in .env

Firewall: allow TCP ${OPENBIN_PORT} and ${OPENAPK_PORT} to this host. Nothing else is exposed.
SUMMARY
  if [ -n "${ADMIN_INITIAL_PASSWORD:-}" ]; then
    cat <<SUMMARY

First sign-in (you will be asked to choose a new password):
  email:    ${ADMIN_EMAIL}
  password: ${ADMIN_INITIAL_PASSWORD}
SUMMARY
  fi
  if [ "${SELF_REGISTRATION:-false}" = true ]; then
    cat <<SUMMARY

Accounts: anyone who can reach ${APP_URL}/ can create their own account
("Register" on the sign-in page). To use your directory instead:
  bin/openbin-enterprise ldap connect --help
To close sign-up:  ./install.sh --no-self-registration
SUMMARY
  else
    cat <<SUMMARY

Accounts: sign-up is closed. Add people at ${AUTH_URL}/admin/ (realm
"openapk"), connect your directory (bin/openbin-enterprise ldap connect --help),
or open sign-up with ./install.sh --self-registration
SUMMARY
  fi
  if [ "${TLS_MODE}" = selfsigned ]; then
    cat <<SUMMARY

The certificate comes from this install's own CA, so browsers show a
warning once per address. To remove it, import the CA on analyst machines:
  ${APP_URL}/downloads/openbin-ca.crt     (or: bin/openbin-enterprise ca-cert)
SUMMARY
  fi
  cat <<SUMMARY

Next:
  1. Sign in at ${APP_URL}/ and add a model under Settings > API keys.
     For a model server on your network use the OpenAI-compatible provider;
     its host must be listed in LLM_EGRESS_ALLOWLIST (--llm-allow).
  2. Optional: analysts who want the CLI install it from ${APP_URL}/downloads/
     and run   openbin login --server ${API_URL}

Changed address or blocked port? Re-run install.sh with --ip / --openbin-port /
--openapk-port; data and accounts are kept.
SUMMARY
}

print_summary_domain() {
  local kc_user
  kc_user="${KEYCLOAK_ADMIN_USER:-admin}"
  cat <<SUMMARY

${C_OK}OpenBin Enterprise is configured.${C_0}

  OpenBin (native binaries, scripts)   ${APP_URL}
  OpenAPK (Android)                    ${APK_URL}
  Sign-in / user admin (Keycloak)      ${AUTH_URL}/admin/   user: ${kc_user}  password: in .env (KEYCLOAK_ADMIN_PASSWORD)
  API                                  ${API_URL}
  Object storage (presigned URLs)      ${S3_URL}
  CLI + BINNY downloads                ${APP_URL}/downloads/

DNS: point these five names at this host:
  ${APP_HOST}  ${APK_HOST}  ${API_HOST}  ${AUTH_HOST}  ${S3_HOST}
SUMMARY
  if [ "${TLS_MODE:-internal}" = internal ]; then
    cat <<SUMMARY

TLS is issued by this install's own CA. Export the root certificate and
distribute it to analyst machines (browsers, OS trust store, Docker):
  bin/openbin-enterprise ca-cert > openbin-root-ca.crt
See docs/tls.md for per-OS steps.
SUMMARY
  fi
  cat <<SUMMARY

First steps:
  1. Open ${AUTH_URL}/admin/, sign in as ${kc_user}, and create a
     permanent admin user (the bootstrap account is temporary by design).
  2. Create user accounts, or connect your identity provider: docs/sso.md.
  3. Sign in at ${APP_URL} with ${ADMIN_EMAIL}; add an LLM key under
     Settings > API keys (internal gateways: set LLM_EGRESS_ALLOWLIST in .env).
  4. Analysts install the CLI from ${APP_URL}/downloads/ and run
       openbin login --server ${API_URL}
SUMMARY
}
