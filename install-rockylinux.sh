#!/usr/bin/env bash
# Install/upgrade go-tasks (api + ui + valkey + caddy) on Rocky Linux 10.
# Idempotent. Re-run any time go-tasks-api or go-tasks-ui has a new release.
set -euo pipefail

# ---------- knobs ---------------------------------------------------------
SITE_ADDRESS="${SITE_ADDRESS:-go-tasks.home.local}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.home.local:8200}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/go-tasks}"
ETC_DIR="${ETC_DIR:-/etc/go-tasks}"
VAULT_AUTH_FILE="${ETC_DIR}/vault-auth.env"
GOTASKS_USER="${GOTASKS_USER:-gotasks}"
API_PORT="${API_PORT:-8080}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/go-tasks}"
BACKUP_KEEP="${BACKUP_KEEP:-30}"
BACKUP_BEFORE_MIGRATE="${BACKUP_BEFORE_MIGRATE:-1}"

# Rocky 10's default postgresql package is v16; the production server runs 17,
# so pull the matching client from PGDG. Bump when the server upgrades.
PG_CLIENT_VERSION="${PG_CLIENT_VERSION:-17}"
PG_BINDIR="/usr/pgsql-${PG_CLIENT_VERSION}/bin"

VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-1}"

API_REPO="sud0x0/go-tasks-api"
UI_REPO="sud0x0/go-tasks-ui"

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

# ---------- packages ------------------------------------------------------
install_packages() {
  log "installing system packages"
  $SUDO dnf install -y -q epel-release >/dev/null
  $SUDO dnf install -y -q curl jq tar valkey >/dev/null

  if [[ ! -x "$PG_BINDIR/pg_dump" ]]; then
    log "installing PostgreSQL ${PG_CLIENT_VERSION} client (PGDG)"
    if [[ ! -f /etc/yum.repos.d/pgdg-redhat-all.repo ]]; then
      $SUDO dnf install -y -q \
        "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm" \
        >/dev/null
    fi
    # Disable Rocky's bundled postgresql module so PGDG's package wins.
    $SUDO dnf -qy module disable postgresql >/dev/null 2>&1 || true
    $SUDO dnf install -y -q "postgresql${PG_CLIENT_VERSION}" >/dev/null
  fi

  if ! command -v caddy >/dev/null; then
    $SUDO dnf install -y -q 'dnf-command(copr)' >/dev/null
    $SUDO dnf copr enable -y @caddy/caddy >/dev/null
    $SUDO dnf install -y -q caddy >/dev/null
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

  # First-run placeholder so the operator knows where to drop AppRole creds.
  # $SUDO test - $ETC_DIR is mode 750 owned by gotasks, so a non-root operator
  # can't traverse it and a bare [[ -f ]] would falsely report "missing" and
  # clobber the operator's edits on every re-run.
  if ! $SUDO test -f "$VAULT_AUTH_FILE"; then
    $SUDO tee "$VAULT_AUTH_FILE" >/dev/null <<'EOF'
# AppRole credentials for the go-tasks-eso role in Vault.
VAULT_ROLE_ID=
VAULT_SECRET_ID=
EOF
    $SUDO chown "$GOTASKS_USER:$GOTASKS_USER" "$VAULT_AUTH_FILE"
    $SUDO chmod 600 "$VAULT_AUTH_FILE"
  fi
}

# ---------- firewall + valkey --------------------------------------------
configure_firewall() {
  command -v firewall-cmd >/dev/null || return 0
  $SUDO systemctl is-active --quiet firewalld || return 0
  log "opening firewall ports 80/443/$API_PORT"
  for port in 80/tcp 443/tcp "$API_PORT/tcp"; do
    $SUDO firewall-cmd --permanent --query-port="$port" >/dev/null 2>&1 \
      || $SUDO firewall-cmd --permanent --add-port="$port" >/dev/null
  done
  $SUDO firewall-cmd --reload >/dev/null
}

configure_valkey() {
  local conf=/etc/valkey/valkey.conf
  log "configuring valkey (loopback only, no auth)"
  $SUDO sed -i -E \
    -e 's|^bind .*$|bind 127.0.0.1|' \
    -e 's|^# *requirepass .*$|# requirepass disabled (loopback only)|' \
    -e 's|^protected-mode .*$|protected-mode yes|' \
    "$conf"
  # sed silently no-ops on unmatched patterns - verify the binding stuck.
  $SUDO grep -qE '^bind 127\.0\.0\.1( |$)'  "$conf" || die "valkey bind config did not apply - inspect $conf"
  $SUDO grep -qE '^protected-mode yes'      "$conf" || die "valkey protected-mode config did not apply"
  $SUDO systemctl enable --now valkey.service >/dev/null
}

# ---------- vault ---------------------------------------------------------
vault_login() {
  # shellcheck source=/dev/null
  source <($SUDO cat "$VAULT_AUTH_FILE")
  [[ -n "${VAULT_ROLE_ID:-}"   ]] || die "VAULT_ROLE_ID empty in $VAULT_AUTH_FILE"
  [[ -n "${VAULT_SECRET_ID:-}" ]] || die "VAULT_SECRET_ID empty in $VAULT_AUTH_FILE"
  VAULT_TOKEN=$(curl -sk -X POST "$VAULT_ADDR/v1/auth/approle/login" \
    -d "{\"role_id\":\"$VAULT_ROLE_ID\",\"secret_id\":\"$VAULT_SECRET_ID\"}" \
    | jq -r '.auth.client_token // empty')
  [[ -n "$VAULT_TOKEN" && "$VAULT_TOKEN" != "null" ]] || die "Vault login failed"
  unset VAULT_ROLE_ID VAULT_SECRET_ID
}

vault_get() {
  curl -sk -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/go-tasks/data/$1" \
    | jq '.data.data'
}

fetch_secrets() {
  log "fetching secrets from Vault"
  vault_login

  local DB CFG JWT
  DB=$(vault_get api/database)
  CFG=$(vault_get api/config)
  JWT=$(vault_get api/jwt)

  local keys="$ETC_DIR/jwt-keys"
  jq -r '.private_key' <<<"$JWT" | $SUDO tee "$keys/private.pem" >/dev/null
  jq -r '.public_key'  <<<"$JWT" | $SUDO tee "$keys/public.pem"  >/dev/null
  $SUDO chown "$GOTASKS_USER:$GOTASKS_USER" "$keys"/*.pem
  $SUDO chmod 600 "$keys/private.pem"
  $SUDO chmod 644 "$keys/public.pem"

  local env_tmp; env_tmp=$(mktemp)
  {
    echo "# Generated by install-rockylinux.sh - do not edit by hand"
    jq -r 'to_entries[] | "DB_\(.key | ascii_upcase)=\(.value)"' <<<"$DB"
    # Loopback Valkey, no auth - VALKEY_PASSWORD intentionally empty.
    echo "VALKEY_URL=127.0.0.1:6379"
    echo "VALKEY_PASSWORD="
    jq -r 'to_entries[] | "\(.key | ascii_upcase)=\(.value)"' <<<"$CFG"
    cat <<EOF
JWT_ISSUER=$(jq -r '.issuer' <<<"$JWT")
JWT_AUDIENCE=$(jq -r '.audience' <<<"$JWT")
JWT_PRIVATE_KEY_PATH=$keys/private.pem
JWT_PUBLIC_KEY_PATH=$keys/public.pem
DB_CONN_MAX_LIFETIME_MINS=5
DB_CONN_MAX_IDLE_TIME_MINS=10
DB_MAX_OPEN_CONNS=100
DB_MAX_IDLE_CONNS=50
EOF
  } > "$env_tmp"
  $SUDO install -o "$GOTASKS_USER" -g "$GOTASKS_USER" -m 600 "$env_tmp" "$ETC_DIR/api.env"
  rm -f "$env_tmp"
  unset VAULT_TOKEN
}

# Pull DB_* into the current shell. Used by pg_dump (backup_database) and the
# migrator (run_migrations) - both read the same DB_* set as the api binary.
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

# Stages downloads in TMP_DIR (a script-level temp). install_migrator and
# install_api_ui consume them in separate steps so we can run migrations
# against the new schema BEFORE the api binary is swapped - if the migrator
# fails, the running api keeps serving on its old binary and old schema.
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

# Migrator binary is a one-shot tool, safe to swap any time. Doing it before
# run_migrations so we run the new release's migrations using the new release's
# migrator (one source of truth - no skew between binary and migration files).
install_migrator() {
  $SUDO install -o "$GOTASKS_USER" -g "$GOTASKS_USER" -m 755 \
    "$TMP_DIR/api/$MIGRATE_BIN_FILE" "$INSTALL_PREFIX/bin/go-tasks-migrator"
}

# Swaps the api binary and the UI doc root. Called only after run_migrations
# succeeds. The previous api binary stays in memory of the running api process
# (Linux replaces the file at the path; in-flight processes keep the old inode)
# so the live api keeps serving until enable_and_start restarts it.
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

# ---------- backup + migrate ---------------------------------------------
backup_database() {
  [[ "$BACKUP_BEFORE_MIGRATE" == "1" ]] || { log "BACKUP_BEFORE_MIGRATE=0 - skipping"; return 0; }
  load_db_env
  local stamp out pg_dump_bin
  stamp=$(date +%Y%m%d-%H%M%S)
  out="$BACKUP_DIR/${DB_NAME}-${stamp}.sql.gz"
  pg_dump_bin="$PG_BINDIR/pg_dump"
  [[ -x "$pg_dump_bin" ]] || pg_dump_bin=$(command -v pg_dump || true)
  [[ -x "$pg_dump_bin" ]] || die "pg_dump not found"
  log "backing up $DB_NAME -> $out"
  PGPASSWORD="$DB_PASSWORD" "$pg_dump_bin" \
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
After=network-online.target valkey.service
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
EOF

  # tls internal -> Caddy's local CA; home.local has no public DNS for ACME.
  $SUDO tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
{
	auto_https disable_redirects
}

{$SITE_ADDRESS} {
	root * {$SITE_ROOT}
	encode zstd gzip
	tls internal

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
		reverse_proxy {$API_UPSTREAM} {
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
  $SUDO systemctl enable --now valkey.service caddy.service go-tasks-api.service >/dev/null
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
  $SUDO systemctl disable --now go-tasks-api.service caddy.service valkey.service 2>/dev/null || true
  log "removing artifacts"
  $SUDO rm -rf "$INSTALL_PREFIX" "$ETC_DIR" \
    /etc/systemd/system/go-tasks-api.service \
    /etc/systemd/system/caddy.service.d/override.conf \
    /etc/caddy/Caddyfile
  $SUDO systemctl daemon-reload
  if id "$GOTASKS_USER" >/dev/null 2>&1; then
    # -r removes the user's home dir; INSTALL_PREFIX is already gone above
    # but keeping -r defends against future reorderings of this function.
    $SUDO userdel -r "$GOTASKS_USER" 2>/dev/null || true
  fi
  log "uninstall complete (valkey + caddy packages left in place)"
}

# ---------- main ----------------------------------------------------------
case "${1:-}" in
  uninstall|--uninstall) uninstall; exit 0 ;;
esac

# Single temp dir for the whole script run; EXIT trap cleans it up reliably
# even if a function exits early via die.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

install_packages
create_user
setup_dirs
configure_firewall
configure_valkey

if ! $SUDO grep -q '^VAULT_ROLE_ID=..*' "$VAULT_AUTH_FILE" 2>/dev/null; then
  die "edit $VAULT_AUTH_FILE (sudo vim) with your AppRole RoleID + SecretID, then re-run"
fi

fetch_secrets
download_releases
write_systemd_units
install_migrator     # safe to swap any time - it's a one-shot tool
backup_database
run_migrations       # if this fails, set -e exits; api binary is NOT yet swapped
install_api_ui       # only reached on migration success
enable_and_start

log "done"
log "  curl -k --resolve $SITE_ADDRESS:443:127.0.0.1 https://$SITE_ADDRESS/health"
log "  systemctl status valkey caddy go-tasks-api"
