#!/usr/bin/env bash
# Shared helpers for install.sh and bin/openbin-enterprise. Sourced, not run.

C_INFO=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OK=$'\033[32m'; C_0=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C_INFO" "$C_0" "$*"; }
ok()   { printf '%s==>%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }
banner() { printf '\n%s\n%s\n\n' "$*" "$(printf '%*s' "${#1}" '' | tr ' ' '=')"; }

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed (https://docs.docker.com/engine/install/)"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running? are you in the docker group?)"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required ('docker compose', not 'docker-compose')"
  command -v openssl >/dev/null 2>&1 || die "openssl is required to generate secrets"
}

compose() { (cd "$ROOT" && docker compose --env-file .env "$@"); }

load_env() {
  [ -f "$ROOT/.env" ] || die "no .env in $ROOT; run ./install.sh first"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
}

random_token() {
  # URL-safe, no padding characters that would need quoting in .env.
  openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-"${1:-32}"
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
  else (echo >"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; fi
}

# ---- rendering ---------------------------------------------------------------
render_caddyfile() {
  local tls_block
  case "${TLS_MODE:-internal}" in
    internal) tls_block="	tls internal" ;;
    acme)     tls_block="" ;;
    custom)   tls_block="	tls /etc/openbin/tls/fullchain.pem /etc/openbin/tls/privkey.pem" ;;
    *) die "TLS_MODE must be internal, acme or custom (got '${TLS_MODE}')" ;;
  esac
  local global=""
  if [ "${TLS_MODE:-internal}" = acme ]; then
    [ -n "${ACME_EMAIL:-}" ] || die "ACME_EMAIL is required when TLS_MODE=acme"
    global="	email ${ACME_EMAIL}"
  fi
  cat > "$ROOT/config/Caddyfile" <<CADDY
# Generated from .env by bin/openbin-enterprise render. Do not hand-edit.
{
	admin off
${global}
}

(site) {
${tls_block}
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
}

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

https://${AUTH_HOST} {
	import site
	reverse_proxy keycloak:8080
}

https://${S3_HOST} {
	import site
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

render_realm() {
  local app="https://${APP_HOST}" apk="https://${APK_HOST}"
  local reg="${SELF_REGISTRATION:-false}"
  [ "$reg" = true ] || reg=false
  sed -e "s#__APP_ORIGIN__#${app}#g" \
      -e "s#__APK_ORIGIN__#${apk}#g" \
      -e "s#__REGISTRATION_ALLOWED__#${reg}#g" \
      -e "s#__CORE_CLIENT_SECRET__#${KEYCLOAK_CORE_CLIENT_SECRET}#g" \
      "$ROOT/config/keycloak/realm.tmpl.json" > "$ROOT/config/keycloak/import/realm-openapk.json"
  chmod 600 "$ROOT/config/keycloak/import/realm-openapk.json"
}

render_all() {
  info "rendering proxy and realm configuration for ${OPENBIN_DOMAIN}"
  render_caddyfile
  render_realm
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
        healthy) ok "backend healthy"; return 0 ;;
        exited|dead) compose logs --tail 60 core; die "backend exited during startup; see the log above" ;;
      esac
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { compose logs --tail 60 core; die "backend not healthy after ${1:-600}s"; }
    printf '.'; sleep 5
  done
}

print_summary() {
  local kc_user kc_pw
  kc_user="${KEYCLOAK_ADMIN_USER:-admin}"; kc_pw="${KEYCLOAK_ADMIN_PASSWORD:-<see .env>}"
  cat <<SUMMARY

${C_OK}OpenBin Enterprise is configured.${C_0}

  OpenBin (native binaries, scripts)   https://${APP_HOST}
  OpenAPK (Android)                    https://${APK_HOST}
  Sign-in / user admin (Keycloak)      https://${AUTH_HOST}/admin/   user: ${kc_user}  password: in .env (KEYCLOAK_ADMIN_PASSWORD)
  API                                  https://${API_HOST}
  Object storage (presigned URLs)      https://${S3_HOST}
  CLI + BINNY downloads                https://${APP_HOST}/downloads/

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
  1. Open https://${AUTH_HOST}/admin/, sign in as ${kc_user}, and create a
     permanent admin user (the bootstrap account is temporary by design).
  2. Create user accounts, or connect your identity provider: docs/sso.md.
  3. Sign in at https://${APP_HOST} with ${ADMIN_EMAIL}; add an LLM key under
     Settings > API keys (internal gateways: set LLM_EGRESS_ALLOWLIST in .env).
  4. Analysts install the CLI from https://${APP_HOST}/downloads/ and run
       openbin login --server https://${API_HOST}

Day two: bin/openbin-enterprise status | logs | backup | upgrade | ca-cert
SUMMARY
}
