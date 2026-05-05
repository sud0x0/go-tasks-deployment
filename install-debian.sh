#!/usr/bin/env bash
# Install/upgrade go-tasks (api + ui + valkey/redis + caddy + postgresql) on
# Debian or Ubuntu. PostgreSQL runs on this host (no Vault, no remote DB).
# Idempotent. Re-run for upgrades.
#
# First run: prompts interactively for config and saves answers to
# /etc/go-tasks/install.env. Subsequent runs are non-interactive.
# Override any value via env vars on the command line.
set -euo pipefail

# ---------- knobs ---------------------------------------------------------
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/go-tasks}"
ETC_DIR="${ETC_DIR:-/etc/go-tasks}"
GOTASKS_USER="${GOTASKS_USER:-gotasks}"
API_PORT="${API_PORT:-8080}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/go-tasks}"
BACKUP_KEEP="${BACKUP_KEEP:-30}"
BACKUP_BEFORE_MIGRATE="${BACKUP_BEFORE_MIGRATE:-1}"

VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-1}"

API_REPO="sud0x0/go-tasks-api"
UI_REPO="sud0x0/go-tasks-ui"

# Persisted operator answers - written on first run, sourced on every run.
INSTALL_ENV_FILE="${ETC_DIR}/install.env"

# ---------- helpers -------------------------------------------------------
log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[install]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

if   [[ $EUID -eq 0 ]];        then SUDO=""
elif sudo -n true 2>/dev/null; then SUDO="sudo"
else die "run as root or with passwordless sudo"
fi

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac

# Cache backend - prefer valkey-server, fall back to redis-server. Recorded
# at install_packages time and reused by configure_cache + systemd unit.
CACHE_PKG=""
CACHE_CONF=""
CACHE_SVC=""

# Minimal SQL string-literal escape for embedding the DB password in
# CREATE/ALTER USER statements.
sql_escape() { printf "%s" "$1" | sed "s/'/''/g"; }

# ---------- prompt --------------------------------------------------------

# prompt_var NAME "Description" "default"
# Skips the prompt if NAME is already set in the environment.
prompt_var() {
  local name="$1" desc="$2" default="$3"
  if [[ -n "${!name:-}" ]]; then return 0; fi
  read -r -p "$desc [$default]: " answer </dev/tty
  printf -v "$name" '%s' "${answer:-$default}"
}

# prompt_secret NAME "Description"
# Same as prompt_var but reads silently and refuses empty input.
prompt_secret() {
  local name="$1" desc="$2"
  if [[ -n "${!name:-}" ]]; then return 0; fi
  while [[ -z "${!name:-}" ]]; do
    read -rs -p "$desc: " answer </dev/tty
    echo
    if [[ -z "$answer" ]]; then
      echo "  (cannot be empty)"
      continue
    fi
    printf -v "$name" '%s' "$answer"
  done
}

# Best-effort host IP for the SITE_ADDRESS default. Falls back to 127.0.0.1
# if no non-loopback v4 is found.
default_site_address() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -n "$ip" ]] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  printf '%s' "${ip:-127.0.0.1}"
}

# Source any persisted answers, then prompt for whatever's still missing,
# then write them back so the next run is non-interactive.
prompt_config() {
  if [[ -f "$INSTALL_ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source <($SUDO cat "$INSTALL_ENV_FILE")
  fi

  local default_tz="Australia/Melbourne"
  [[ -f /etc/timezone ]] && default_tz=$(cat /etc/timezone)

  log "configuration (Enter accepts the default in [brackets])"
  # SITE_ADDRESS may be a domain, a hostname, or a bare IPv4. Caddy serves
  # all three forms - just the TLS issuer differs (see ACME_EMAIL below).
  prompt_var SITE_ADDRESS         "Site address (domain or IP)"     "$(default_site_address)"
  prompt_var DB_NAME              "PostgreSQL database name"        "gotasks"
  prompt_var DB_USER              "PostgreSQL user"                 "gotasks"
  prompt_secret DB_PASSWORD       "PostgreSQL password"
  # ACME_EMAIL empty -> Caddy uses its local CA (tls internal). Set to a
  # real address ONLY when SITE_ADDRESS is a public domain that resolves
  # to this host on 80/443; Let's Encrypt won't issue for IPs or *.local.
  prompt_var ACME_EMAIL           "ACME email (blank = tls internal)" ""
  prompt_var JWT_ISSUER           "JWT issuer"                      "go-tasks-api"
  prompt_var JWT_AUDIENCE         "JWT audience"                    "go-tasks-api"
  prompt_var CORS_ALLOWED_ORIGINS "CORS allowed origins"            "https://${SITE_ADDRESS}"
  prompt_var LOG_LEVEL            "API log level"                   "production"
  prompt_var TZ_VALUE             "Timezone"                        "$default_tz"

  $SUDO mkdir -p "$ETC_DIR"
  $SUDO tee "$INSTALL_ENV_FILE" >/dev/null <<EOF
# Persisted answers from install-debian.sh - sourced on every re-run.
# Edit a value here and re-run the script to apply it.
SITE_ADDRESS=$SITE_ADDRESS
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
ACME_EMAIL=$ACME_EMAIL
JWT_ISSUER=$JWT_ISSUER
JWT_AUDIENCE=$JWT_AUDIENCE
CORS_ALLOWED_ORIGINS=$CORS_ALLOWED_ORIGINS
LOG_LEVEL=$LOG_LEVEL
TZ_VALUE=$TZ_VALUE
EOF
  $SUDO chmod 600 "$INSTALL_ENV_FILE"
}

# ---------- packages ------------------------------------------------------
install_packages() {
  log "installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq curl jq tar openssl postgresql

  # Pick the cache backend that's available.
  if apt-cache show valkey-server >/dev/null 2>&1; then
    CACHE_PKG=valkey-server
    CACHE_CONF=/etc/valkey/valkey.conf
    CACHE_SVC=valkey-server.service
  else
    CACHE_PKG=redis-server
    CACHE_CONF=/etc/redis/redis.conf
    CACHE_SVC=redis-server.service
  fi
  $SUDO apt-get install -y -qq "$CACHE_PKG"

  if ! command -v caddy >/dev/null; then
    log "installing caddy from cloudsmith repo"
    $SUDO apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | $SUDO gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq caddy
  fi
}

# ---------- user + dirs ---------------------------------------------------
create_user() {
  id "$GOTASKS_USER" >/dev/null 2>&1 && return 0
  log "creating user $GOTASKS_USER"
  $SUDO useradd --system --home-dir "$INSTALL_PREFIX" --shell /usr/sbin/nologin "$GOTASKS_USER"
}

setup_dirs() {
  log "preparing directories"
  $SUDO mkdir -p "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/ui" "$ETC_DIR/jwt-keys"
  $SUDO chown -R "$GOTASKS_USER:$GOTASKS_USER" "$INSTALL_PREFIX" "$ETC_DIR"
  $SUDO chmod 750 "$ETC_DIR" "$ETC_DIR/jwt-keys"
  if [[ "$BACKUP_BEFORE_MIGRATE" == "1" ]]; then
    $SUDO mkdir -p "$BACKUP_DIR"
    $SUDO chmod 700 "$BACKUP_DIR"
  fi
}

# ---------- firewall ------------------------------------------------------
configure_firewall() {
  command -v ufw >/dev/null || return 0
  $SUDO ufw status 2>/dev/null | grep -q "Status: active" || return 0
  log "opening ufw ports 80/443/$API_PORT"
  for port in 80/tcp 443/tcp "$API_PORT/tcp"; do
    $SUDO ufw allow "$port" >/dev/null
  done
}

# ---------- postgres ------------------------------------------------------
configure_postgres() {
  log "configuring postgresql (database + user)"
  $SUDO systemctl enable --now postgresql >/dev/null

  local pw_esc; pw_esc=$(sql_escape "$DB_PASSWORD")

  # Idempotent user creation/password reset.
  if [[ "$($SUDO -u postgres psql -tAc "SELECT 1 FROM pg_user WHERE usename='$DB_USER'")" != "1" ]]; then
    $SUDO -u postgres psql -v ON_ERROR_STOP=1 -c \
      "CREATE USER \"$DB_USER\" WITH PASSWORD '$pw_esc';" >/dev/null
  else
    $SUDO -u postgres psql -v ON_ERROR_STOP=1 -c \
      "ALTER USER \"$DB_USER\" WITH PASSWORD '$pw_esc';" >/dev/null
  fi

  if [[ "$($SUDO -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")" != "1" ]]; then
    $SUDO -u postgres createdb -O "$DB_USER" "$DB_NAME"
  fi
}

# ---------- cache ---------------------------------------------------------
configure_cache() {
  log "configuring $CACHE_PKG (loopback only, no auth)"
  $SUDO sed -i -E \
    -e 's|^bind .*$|bind 127.0.0.1|' \
    -e 's|^# *requirepass .*$|# requirepass disabled (loopback only)|' \
    -e 's|^protected-mode .*$|protected-mode yes|' \
    "$CACHE_CONF"
  $SUDO grep -qE '^bind 127\.0\.0\.1( |$)' "$CACHE_CONF" || die "cache bind config did not apply - inspect $CACHE_CONF"
  $SUDO grep -qE '^protected-mode yes'     "$CACHE_CONF" || die "cache protected-mode config did not apply"
  $SUDO systemctl enable --now "$CACHE_SVC" >/dev/null
}

# ---------- jwt keys ------------------------------------------------------
generate_jwt_keys() {
  local keys="$ETC_DIR/jwt-keys"
  if [[ -f "$keys/private.pem" && -f "$keys/public.pem" ]]; then
    return 0
  fi
  log "generating JWT RSA-4096 keypair"
  $SUDO openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
    -out "$keys/private.pem"
  $SUDO openssl rsa -in "$keys/private.pem" -pubout -out "$keys/public.pem" 2>/dev/null
  $SUDO chown -R "$GOTASKS_USER:$GOTASKS_USER" "$keys"
  $SUDO chmod 600 "$keys/private.pem"
  $SUDO chmod 644 "$keys/public.pem"
}

# ---------- api.env ------------------------------------------------------
write_api_env() {
  log "writing api.env"
  local env_tmp; env_tmp=$(mktemp)
  local keys="$ETC_DIR/jwt-keys"
  cat > "$env_tmp" <<EOF
# Generated by install-debian.sh - do not edit by hand.
# Edit $INSTALL_ENV_FILE then re-run the script to apply changes.
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_SSLMODE=disable
VALKEY_URL=127.0.0.1:6379
VALKEY_PASSWORD=
PORT=$API_PORT
LOG_LEVEL=$LOG_LEVEL
CORS_ALLOWED_ORIGINS=$CORS_ALLOWED_ORIGINS
TZ=$TZ_VALUE
JWT_ISSUER=$JWT_ISSUER
JWT_AUDIENCE=$JWT_AUDIENCE
JWT_PRIVATE_KEY_PATH=$keys/private.pem
JWT_PUBLIC_KEY_PATH=$keys/public.pem
DB_CONN_MAX_LIFETIME_MINS=5
DB_CONN_MAX_IDLE_TIME_MINS=10
DB_MAX_OPEN_CONNS=100
DB_MAX_IDLE_CONNS=50
EOF
  $SUDO install -o "$GOTASKS_USER" -g "$GOTASKS_USER" -m 600 "$env_tmp" "$ETC_DIR/api.env"
  rm -f "$env_tmp"
}

# Sources DB_* into the current shell - used by pg_dump (backup) and the
# migrator (which reads the same DB_* set as the api binary).
load_db_env() {
  set -a
  # shellcheck source=/dev/null
  source <($SUDO cat "$ETC_DIR/api.env")
  set +a
}

# ---------- releases ------------------------------------------------------
gh_latest_tag() {
  curl -sf ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name'
}

download_release() {
  local repo="$1" tag="$2" file="$3" dest="$4"
  curl -sfL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://github.com/$repo/releases/download/$tag/$file" -o "$dest"
}

verify_checksums() {
  [[ "$VERIFY_CHECKSUMS" == "1" ]] || return 0
  local repo="$1" tag="$2" dir="$3"
  download_release "$repo" "$tag" "checksums.txt" "$dir/checksums.txt"
  log "verifying SHA-256 of $repo@$tag"
  ( cd "$dir" && sha256sum -c --ignore-missing --quiet checksums.txt ) \
    || die "checksum verification failed for $repo@$tag"
}

# Stages downloads in TMP_DIR; install_migrator and install_api_ui consume
# them in separate steps so migrations run BEFORE the api binary is swapped.
download_releases() {
  API_TAG="${API_TAG:-$(gh_latest_tag "$API_REPO")}"
  UI_TAG="${UI_TAG:-$(gh_latest_tag "$UI_REPO")}"
  [[ -n "$API_TAG" && -n "$UI_TAG" ]] || die "could not resolve release tags"
  log "api=$API_TAG ui=$UI_TAG"

  local v="${API_TAG#v}" uv="${UI_TAG#v}"
  mkdir -p "$TMP_DIR/api" "$TMP_DIR/ui"

  # Filenames must match the keys in checksums.txt for the verify step.
  API_BIN_FILE="go-tasks-api-${v}_linux_${ARCH}"
  MIGRATE_BIN_FILE="go-tasks-database-migrator-${v}_linux_${ARCH}"
  UI_TARBALL_FILE="go-tasks-ui-${uv}.tar.gz"

  download_release "$API_REPO" "$API_TAG" "$API_BIN_FILE"     "$TMP_DIR/api/$API_BIN_FILE"
  download_release "$API_REPO" "$API_TAG" "$MIGRATE_BIN_FILE" "$TMP_DIR/api/$MIGRATE_BIN_FILE"
  download_release "$UI_REPO"  "$UI_TAG"  "$UI_TARBALL_FILE"  "$TMP_DIR/ui/$UI_TARBALL_FILE"

  verify_checksums "$API_REPO" "$API_TAG" "$TMP_DIR/api"
  verify_checksums "$UI_REPO"  "$UI_TAG"  "$TMP_DIR/ui"
}

install_migrator() {
  $SUDO install -o "$GOTASKS_USER" -g "$GOTASKS_USER" -m 755 \
    "$TMP_DIR/api/$MIGRATE_BIN_FILE" "$INSTALL_PREFIX/bin/go-tasks-migrator"
}

install_api_ui() {
  log "installing new api binary + UI bundle"
  $SUDO install -o "$GOTASKS_USER" -g "$GOTASKS_USER" -m 755 \
    "$TMP_DIR/api/$API_BIN_FILE" "$INSTALL_PREFIX/bin/go-tasks-api"

  # Tarball stages as go-tasks-ui-<v>/{Caddyfile,index.html,assets/}.
  # Strip the wrapper, drop the shipped Caddyfile (we own /etc/caddy/Caddyfile),
  # and atomic-swap the doc root.
  $SUDO rm -rf "$INSTALL_PREFIX/ui/dist.new" "$INSTALL_PREFIX/ui/dist.old"
  $SUDO mkdir -p "$INSTALL_PREFIX/ui/dist.new"
  $SUDO tar -xzf "$TMP_DIR/ui/$UI_TARBALL_FILE" -C "$INSTALL_PREFIX/ui/dist.new" --strip-components=1
  $SUDO rm -f "$INSTALL_PREFIX/ui/dist.new/Caddyfile"
  [[ -d "$INSTALL_PREFIX/ui/dist" ]] && $SUDO mv "$INSTALL_PREFIX/ui/dist" "$INSTALL_PREFIX/ui/dist.old"
  $SUDO mv "$INSTALL_PREFIX/ui/dist.new" "$INSTALL_PREFIX/ui/dist"
  $SUDO rm -rf "$INSTALL_PREFIX/ui/dist.old"
  $SUDO chown -R "$GOTASKS_USER:$GOTASKS_USER" "$INSTALL_PREFIX/ui"
}

# ---------- backup + migrate ----------------------------------------------
backup_database() {
  [[ "$BACKUP_BEFORE_MIGRATE" == "1" ]] || { log "BACKUP_BEFORE_MIGRATE=0 - skipping"; return 0; }
  load_db_env
  local stamp out
  stamp=$(date +%Y%m%d-%H%M%S)
  out="$BACKUP_DIR/${DB_NAME}-${stamp}.sql.gz"
  log "backing up $DB_NAME -> $out"
  PGPASSWORD="$DB_PASSWORD" pg_dump \
      -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" \
    | gzip -c | $SUDO tee "$out" >/dev/null
  $SUDO chmod 600 "$out"
  unset PGPASSWORD

  if [[ "$BACKUP_KEEP" -gt 0 ]]; then
    local stale
    stale=$($SUDO bash -c "ls -1t '$BACKUP_DIR'/${DB_NAME}-*.sql.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1))")
    if [[ -n "$stale" ]]; then
      printf '%s\n' "$stale" | $SUDO xargs rm -f
      log "  pruned $(printf '%s\n' "$stale" | wc -l) old backup(s)"
    fi
  fi
}

run_migrations() {
  log "running database migrations"
  load_db_env
  "$INSTALL_PREFIX/bin/go-tasks-migrator" up
  unset DB_PASSWORD
}

# ---------- systemd + caddy ----------------------------------------------
write_systemd_units() {
  log "writing systemd units + Caddyfile"
  $SUDO tee /etc/systemd/system/go-tasks-api.service >/dev/null <<EOF
[Unit]
Description=go-tasks API
After=network-online.target postgresql.service $CACHE_SVC
Wants=network-online.target

[Service]
Type=simple
User=$GOTASKS_USER
Group=$GOTASKS_USER
EnvironmentFile=$ETC_DIR/api.env
ExecStart=$INSTALL_PREFIX/bin/go-tasks-api
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$ETC_DIR/jwt-keys

[Install]
WantedBy=multi-user.target
EOF

  $SUDO mkdir -p /etc/systemd/system/caddy.service.d
  $SUDO tee /etc/systemd/system/caddy.service.d/override.conf >/dev/null <<EOF
[Service]
Environment=SITE_ADDRESS=$SITE_ADDRESS
Environment=API_UPSTREAM=127.0.0.1:$API_PORT
Environment=SITE_ROOT=$INSTALL_PREFIX/ui/dist
Environment=ACME_EMAIL=$ACME_EMAIL
EOF

  # Two TLS modes:
  #  - ACME_EMAIL empty    -> tls internal (Caddy's local CA, works for IPs
  #                            and *.local hosts; clients must trust the CA)
  #  - ACME_EMAIL non-empty -> Let's Encrypt via the global email block
  #                            (requires SITE_ADDRESS to be a real public
  #                            domain that resolves to this host on 80/443)
  local tls_line global_block
  if [[ -n "$ACME_EMAIL" ]]; then
    tls_line="tls {\$ACME_EMAIL}"
    global_block=$'{\n\temail {$ACME_EMAIL}\n}\n'
  else
    tls_line="tls internal"
    global_block=$'{\n\tauto_https disable_redirects\n}\n'
  fi

  $SUDO tee /etc/caddy/Caddyfile >/dev/null <<EOF
${global_block}
{\$SITE_ADDRESS} {
	root * {\$SITE_ROOT}
	encode zstd gzip
	${tls_line}

	header {
		Strict-Transport-Security "max-age=63072000; includeSubDomains"
		X-Content-Type-Options    "nosniff"
		X-Frame-Options           "SAMEORIGIN"
		Referrer-Policy           "strict-origin-when-cross-origin"
		Permissions-Policy        "geolocation=(), microphone=(), camera=()"
		-Server
	}

	@api path /api/* /health
	handle @api {
		reverse_proxy {\$API_UPSTREAM} {
			header_up Host              {host}
			header_up X-Real-IP         {remote_host}
			header_up X-Forwarded-For   {remote_host}
			header_up X-Forwarded-Proto {scheme}
		}
	}

	@assets path *.js *.css *.woff *.woff2 *.png *.svg *.ico
	handle @assets {
		header Cache-Control "public, max-age=31536000, immutable"
		file_server
	}

	handle {
		header Cache-Control "no-store, no-cache, must-revalidate"
		try_files {path} /index.html
		file_server
	}
}
EOF

  $SUDO systemctl daemon-reload
}

enable_and_start() {
  log "enabling + starting services"
  $SUDO systemctl enable --now postgresql "$CACHE_SVC" caddy.service go-tasks-api.service >/dev/null
  $SUDO systemctl restart caddy.service go-tasks-api.service

  log "waiting for go-tasks-api to become active"
  local state=""
  for _ in $(seq 1 30); do
    state=$($SUDO systemctl is-active go-tasks-api.service 2>/dev/null || true)
    [[ "$state" == "active" ]] && break
    sleep 1
  done
  [[ "$state" == "active" ]] || die "go-tasks-api did not start - inspect: journalctl -u go-tasks-api -n 50"
}

# ---------- uninstall -----------------------------------------------------
uninstall() {
  log "stopping services"
  $SUDO systemctl disable --now go-tasks-api.service 2>/dev/null || true
  $SUDO systemctl disable --now caddy.service        2>/dev/null || true
  log "removing artifacts (PostgreSQL data + the gotasks DB are preserved)"
  $SUDO rm -rf "$INSTALL_PREFIX" "$ETC_DIR" \
    /etc/systemd/system/go-tasks-api.service \
    /etc/systemd/system/caddy.service.d/override.conf \
    /etc/caddy/Caddyfile
  $SUDO systemctl daemon-reload
  if id "$GOTASKS_USER" >/dev/null 2>&1; then
    $SUDO userdel -r "$GOTASKS_USER" 2>/dev/null || true
  fi
  log "uninstall complete (postgresql + cache + caddy packages left in place)"
  log "drop the database manually if you don't need it: sudo -u postgres dropdb <name>"
}

# ---------- main ----------------------------------------------------------
case "${1:-}" in
  uninstall|--uninstall) uninstall; exit 0 ;;
esac

# Single temp dir for the whole run; cleaned reliably even on early exit.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

prompt_config
install_packages
create_user
setup_dirs
configure_firewall
configure_postgres
configure_cache
generate_jwt_keys
write_api_env
download_releases
write_systemd_units
install_migrator     # safe to swap any time - it's a one-shot tool
backup_database
run_migrations       # if this fails, set -e exits; api binary is NOT yet swapped
install_api_ui       # only reached on migration success
enable_and_start

log "done"
log "  curl -k --resolve $SITE_ADDRESS:443:127.0.0.1 https://$SITE_ADDRESS/health"
log "  systemctl status postgresql $CACHE_SVC caddy go-tasks-api"
