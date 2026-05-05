# go-tasks-homeserver-setup

Single-script native installers for `go-tasks`. Two flavours, pick one:

| Script                     | Target                | DB location | Secrets source                                |
| -------------------------- | --------------------- | ----------- | --------------------------------------------- |
| `install-rockylinux.sh`    | Rocky Linux 10        | remote      | HashiCorp Vault (AppRole)                     |
| `install-debian.sh`        | Debian / Ubuntu       | local       | interactive prompts on first run              |

No containers in either — Caddy + Valkey/Redis + the Go binaries run directly under systemd.

## Hosts

| Hostname              | IP          | Role                    |
| --------------------- | ----------- | ----------------------- |
| `go-tasks.home.local` | 10.10.30.21 | this installer's target |
| `vault.home.local`    | 10.10.30.12 | Vault                   |
| `db.home.local`       | 10.10.30.14 | PostgreSQL              |

## What it installs

- `valkey` — loopback-only LAN cache, no auth
- `caddy` — TLS via Caddy's internal CA, reverse-proxies `/api/*` + `/health` to the api, serves the UI bundle
- `go-tasks-api` — binary at `/opt/go-tasks/bin/go-tasks-api`, run as the `gotasks` system user
- `go-tasks-database-migrator` — binary at `/opt/go-tasks/bin/`, executed once per run before the api restarts
- `go-tasks-ui` — Vite static bundle at `/opt/go-tasks/ui/dist/`

Binaries and UI tarball are pulled from GitHub releases and verified against the release's `checksums.txt`.

## Prereqs (Rocky / `install-rockylinux.sh`)

- PostgreSQL set up and reachable from this host — see `notes/database-setup.md`
- Vault with the AppRole — see `notes/vault-setup.md`. You'll need the **RoleID** and **SecretID**

## Prereqs (Debian / Ubuntu / `install-debian.sh`)

- None. The script installs PostgreSQL locally and prompts you for the credentials it needs.
- Optional: a public domain pointing at this host (port 80/443) if you want a Let's Encrypt cert. Otherwise `tls internal` is used and works for raw IPs and `*.local` hostnames.

---

## Step 1 — Clone

```bash
sudo dnf install -y git
git clone <this repo> ~/go-tasks-homeserver-setup
cd ~/go-tasks-homeserver-setup
```

## Step 2 — Run the installer

### Rocky Linux 10

```bash
./install-rockylinux.sh
```

First run sets up packages + directories, then exits with:

```
ERROR: edit /etc/go-tasks/vault-auth.env with your AppRole RoleID + SecretID, then re-run
```

Paste the AppRole creds:

```bash
sudo nano /etc/go-tasks/vault-auth.env
# VAULT_ROLE_ID=<paste>
# VAULT_SECRET_ID=<paste>
```

Run again to finish:

```bash
./install-rockylinux.sh
```

### Debian / Ubuntu

```bash
./install-debian.sh
```

First run prompts for everything it needs (Enter accepts the default in `[brackets]`):

```
[install] configuration (Enter accepts the default in [brackets])
Site address (domain or IP)             [10.0.0.42]:
PostgreSQL database name                [gotasks]:
PostgreSQL user                         [gotasks]:
PostgreSQL password:                    ********
ACME email (blank = tls internal)       []:
JWT issuer                              [go-tasks-api]:
JWT audience                            [go-tasks-api]:
CORS allowed origins                    [https://10.0.0.42]:
API log level                           [production]:
Timezone                                [Australia/Melbourne]:
```

Answers persist to `/etc/go-tasks/install.env`. Subsequent runs are non-interactive — pass any var on the command line to override (`SITE_ADDRESS=tasks.example.com ./install-debian.sh`) or edit `install.env` and re-run.

**About `ACME_EMAIL`**: leave blank for homeserver / IP / `*.local` deployments — Caddy uses its own local CA (clients need to trust it). Set to a real address only when `SITE_ADDRESS` is a public domain pointing to this host on 80/443; Let's Encrypt won't issue for IPs.

### What each script does (in order)

Both scripts share the same backbone — the differences are in how they get DB credentials, where Postgres lives, and a few packaging details:

| Step                      | `install-rockylinux.sh`                                        | `install-debian.sh`                                          |
| ------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------ |
| 1. Packages               | `dnf` + EPEL + PGDG (`postgresql${PG_CLIENT_VERSION}` client only) + Caddy from COPR + Valkey | `apt-get` + Caddy from cloudsmith + Postgres + Valkey or Redis (whichever is available) |
| 2. User / dirs / firewall | `gotasks` user, `/opt/go-tasks`, `/etc/go-tasks`, firewalld 80/443/8080 | same dirs, ufw 80/443/8080                                   |
| 3. Cache                  | valkey on 127.0.0.1                                            | valkey or redis on 127.0.0.1                                 |
| 4. Postgres               | n/a (remote DB)                                                | initialise local cluster, create user + DB                   |
| 5. JWT keys               | fetched from Vault                                             | generated locally with openssl on first run                  |
| 6. `api.env`              | written from Vault secrets                                     | written from `install.env` answers                           |
| 7. Releases               | latest `go-tasks-api` + `go-tasks-database-migrator` + `go-tasks-ui` from GitHub, SHA-256 verified, staged in a temp dir | identical                                                    |
| 8. systemd + Caddyfile    | `tls internal`                                                 | `tls internal` if `ACME_EMAIL` is blank, otherwise Let's Encrypt |
| 9. Migrator binary        | installed before migrations run                                | identical                                                    |
| 10. `pg_dump` backup      | to `/var/backups/go-tasks/`                                    | identical                                                    |
| 11. `migrator up`         | runs against remote DB                                         | runs against local DB                                        |
| 12. API binary + UI swap  | only after migrations succeed                                  | identical                                                    |
| 13. Enable + start        | `valkey caddy go-tasks-api`                                    | `postgresql valkey-server caddy go-tasks-api`                |

## Step 3 — Verify

```bash
# Rocky:
systemctl status valkey caddy go-tasks-api
# Debian / Ubuntu:
systemctl status postgresql valkey-server caddy go-tasks-api    # or redis-server

# Both:
curl -k --resolve "$SITE_ADDRESS:443:127.0.0.1" "https://$SITE_ADDRESS/health"
```

If `SITE_ADDRESS` is a hostname rather than an IP, add it to `/etc/hosts` on each LAN client (or to your home DNS):

```
10.0.0.42  go-tasks.home.local
```

`tls internal` deployments: browsers warn until you import Caddy's local CA root from `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt` into the client trust store.

---

## Upgrades

Re-run the same script:

```bash
./install-rockylinux.sh    # or ./install-debian.sh
```

What actually changes on an upgrade run:

- **Packages** — `dnf` / `apt` are no-op when current
- **User / directories / firewall / cache config** — already in place, untouched
- **Secrets** — Rocky: re-fetched from Vault every run, so rotations propagate. Debian: re-read from `install.env` (edit the file to rotate)
- **Releases** — `gh_latest_tag` re-resolves; if the api or ui tag has bumped, the new artifacts download and replace the old (UI swap is atomic via `dist.new → dist` rename)
- **systemd units + Caddyfile** — re-written, but content matches the script's heredocs so they're a no-op unless the script itself changed
- **Backup** — a fresh timestamped `pg_dump` lands in `/var/backups/go-tasks/` (oldest pruned beyond `BACKUP_KEEP`)
- **Migrations** — `migrator up` is idempotent; if there are new migrations they apply, otherwise it logs `no migrations to run`
- **API binary + UI swap** — only happens after `migrator up` succeeds
- **Restart** — `caddy` and `go-tasks-api` always restart; postgres/cache are left alone unless their config changed

Pin specific versions with `API_TAG=v1.2.3 UI_TAG=v1.2.3 ./install-...sh`. Skip the backup with `BACKUP_BEFORE_MIGRATE=0`. Skip checksum verification with `VERIFY_CHECKSUMS=0`.

## Uninstall

```bash
./install-rockylinux.sh uninstall    # or ./install-debian.sh uninstall
```

Stops the services, removes `/opt/go-tasks`, `/etc/go-tasks`, the systemd unit + drop-in, and `/etc/caddy/Caddyfile`. Deletes the `gotasks` user. Leaves the `postgresql` (Debian) / `valkey` / `caddy` packages installed (cheap to keep). The Debian uninstall **does not drop the `gotasks` database** — run `sudo -u postgres dropdb gotasks` manually if you want it gone.

---

## File layout after a successful install

```
/opt/go-tasks/
  bin/go-tasks-api
  bin/go-tasks-migrator
  ui/dist/                          # index.html, assets/, favicon.svg, ...
/etc/go-tasks/
  vault-auth.env                    # Rocky only - AppRole creds (you populate)
  install.env                       # Debian only - persisted prompt answers
  api.env                           # written by script, mode 0600
  jwt-keys/private.pem              # mode 0600 (fetched from Vault on Rocky,
  jwt-keys/public.pem               # mode 0644  generated locally on Debian)
/etc/caddy/Caddyfile                # /api/* + /health → 127.0.0.1:8080
/etc/systemd/system/
  go-tasks-api.service
  caddy.service.d/override.conf     # SITE_ADDRESS, API_UPSTREAM, SITE_ROOT [, ACME_EMAIL]
/var/backups/go-tasks/
  ${DB_NAME}-YYYYMMDD-HHMMSS.sql.gz # pre-migration pg_dump, mode 0600
```

## Knobs (env vars, defaults shown)

Common to both scripts:

- `SITE_ADDRESS=go-tasks.home.local` (Debian default: detected host IP)
- `INSTALL_PREFIX=/opt/go-tasks`
- `ETC_DIR=/etc/go-tasks`
- `API_PORT=8080`
- `API_TAG=` / `UI_TAG=` (empty = latest release)
- `BACKUP_BEFORE_MIGRATE=1`
- `BACKUP_DIR=/var/backups/go-tasks`
- `BACKUP_KEEP=30`
- `VERIFY_CHECKSUMS=1`
- `GITHUB_TOKEN=` (optional; bumps GitHub API rate limits)

Rocky only:

- `VAULT_ADDR=https://vault.home.local:8200`
- `PG_CLIENT_VERSION=17` (bump when the PostgreSQL server upgrades)

Debian only (set on the command line to skip a prompt, or persist via `install.env`):

- `DB_NAME=gotasks`
- `DB_USER=gotasks`
- `DB_PASSWORD=` (no default — must be supplied)
- `JWT_ISSUER=go-tasks-api`
- `JWT_AUDIENCE=go-tasks-api`
- `CORS_ALLOWED_ORIGINS=https://${SITE_ADDRESS}`
- `LOG_LEVEL=production`
- `TZ_VALUE=` (defaults to `/etc/timezone`)
- `ACME_EMAIL=` (blank = `tls internal`; set to enable Let's Encrypt)

## Notes

- **Valkey is loopback-only with no `requirepass`**. The api connects via `127.0.0.1:6379`. Nothing on the LAN can reach the cache.
- **API on 8080 is firewalled open**, so direct API access bypassing Caddy works for tools that don't speak the local TLS root.
- **The migrator and the api read the same `DB_*` env set** (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSLMODE`) — both sourced from `/etc/go-tasks/api.env`.
- **Migrations run before the api binary is swapped.** If a migration fails, `set -e` exits before the new api binary moves into place; the running api keeps serving on its old binary, the pre-migration `pg_dump` is in `/var/backups/go-tasks/`, and `migrator up` is idempotent so re-running picks up where you left off.

## License

[MIT](LICENSE).
