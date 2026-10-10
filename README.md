# RF Online: Golden Age (rf2232) in Docker

This project runs the GoMMO rf2232 server bundle (gameserver and website) on Linux with
Docker. You may be configure everything in `.env` and run/manage it with `./rfctl`.

Example project structure
```
RFOnline_GoMMO/
├── rf2232-v0.7.0/          the unpacked server bundle (RF_BUNDLE_DIR), not modified
└── docker/
    ├── rfctl               management script (start here)
    ├── .env.example        every setting; copied to .env on first run
    ├── docker-compose.yml  services: mysql (optional), init, gameserver, webserver, backup
    ├── docker-compose.tls.yml  HTTPS overlay (added automatically when RF_TLS_DOMAIN is set)
    ├── Dockerfile          builds the images (targets: gameserver, webserver, tools)
    ├── tools/rf-tools.sh   init, schema, DB check, backup and restore logic (inside the tools image)
    └── data/               all server state (RF_DATA_DIR), created on first start
```

## Requirements

- Linux x86-64 with Docker Engine 24+ and the Compose plugin v2.20+.
- The unpacked bundle next to this folder. Set `RF_BUNDLE_DIR` if it lives somewhere else.

## Quick start

```bash
cd docker
./rfctl up          # first run creates .env, builds the images, starts everything
```

`rfctl up` does the following:

1. Builds the images if they don't exist yet.
2. If `RF_DB_PROVIDER=mysql`, starts MySQL and waits until it is healthy.
3. Runs **init**. Init renders `settings.cfg` from `.env` and writes `manager.ini`. It
   installs the stock content database and copies the launcher files into `data/client`,
   with your public host and ports filled in. On MySQL, it also creates the databases
   and the app user, and applies the `database-mysql` schema if it is missing.
4. Starts the gameserver and waits for it to log `gameserver started`.
5. Starts the webserver and the backup scheduler.
6. Inspects the database and prints the schema state (see
   [Schema tracking](#schema-tracking)).
7. Prints the URLs. If nobody is an administrator yet, it also prints the one-time
   **control panel password**: sign in at `/login/` with your own email and that password
   to become Super Administrator.

Before you open the server to other players, edit `.env`. At minimum, set
`RF_PUBLIC_HOST`, and the passwords if you use MySQL.

### Moving an existing install into Docker

If you have already run the bundle directly (with GoMMO_Manager or `start-server.sh`),
copy its data in. The command copies the SQLite databases, `webassets/` and `custom/`:

```bash
./rfctl import ../rf2232-v0.6.0                  # add --with-backups to copy backups/ too
./rfctl up
```

## Ports

| Port (default) | What | Setting |
|---|---|---|
| 27800/tcp | Game client socket | `RF_SERVICE_PORT` |
| 27801/tcp | Launcher (always game port + 1) | derived |
| 8080/tcp | Website and control panel (HTTP) | `RF_WEB_PORT` |
| 80, 443/tcp | Website with HTTPS (only when `RF_TLS_DOMAIN` is set) | |

The gameserver's live-stats port (29913) and pprof listen on loopback only. The
webserver reads stats from `127.0.0.1:29913`, a hardcoded address. For that reason, the
webserver container shares the gameserver's network namespace, and all published ports
are on the `gameserver` service.

## Configuration (.env)

Init applies every `RF_*` value to `settings/settings.cfg` on each start, so `.env` is
the source of truth. Don't edit `settings.cfg` by hand: the next start overwrites it. To
apply a change, run `./rfctl restart`. The full list with comments is in
`.env.example`. The main settings:

| Variable | settings.cfg key / effect |
|---|---|
| `RF_PUBLIC_HOST` | `Host =` in the launcher.ini that the website hands out |
| `RF_LAUNCHER_UPDATE_URL` | `[Update] URL` in launcher.ini (client patch source) |
| `RF_SERVICE_PORT` | `SERVICE_PORT`; also published, launcher = +1 |
| `RF_WEB_PORT` | host port of the website |
| `RF_MAX_SESSIONS`, `RF_ALLOW_SCRIPTED_CLIENTS`, `RF_DEBUG`, `RF_PROFILE_PORT` | same-named keys |
| `RF_DB_PROVIDER` | `DATABASE_PROVIDER`: `sqlite` or `mysql` |
| `RF_DB_HOST/PORT/USER/PASSWORD` | `DATABASE_HOST/PORT/USERNAME/PASSWORD` |
| `RF_DB_ACCOUNTS/GAME/GAMEDATA` | `DATABASE_DSN_ACCOUNT/GAME/GAMEDATA` |
| `RF_GAMEDATA_MODE`, `RF_LEGACY_PATH`, `RF_CLIENT_PATH`, `RF_LEGACY_ZONES` | `[gamedata]` |
| `RF_COOKIE_DOMAIN`, `RF_TLS_DOMAIN` | `[webserver]` |
| `RF_UPDATE_URL`, `RF_UPDATE_CHANNEL` | `[update]` |
| `RF_BACKUP_EVERY_HOURS`, `RF_BACKUP_KEEP` | backup scheduler, and `manager.ini` for the panel |
| `RF_UID`, `RF_GID` | host user that owns `data/` and runs the servers |
| `TZ` | time zone for logs and backup names |

`SUPER_PASSWORD` is never touched. The webserver manages it.

## SQLite or MySQL

**SQLite** (default): the databases are files in `data/db/`. Nothing else to run.

**MySQL**: set these in `.env`:

```ini
RF_DB_PROVIDER=mysql
RF_MYSQL_BUNDLED=1            # run the bundled mysql:8.4 container
RF_DB_USER=rf2232
RF_DB_PASSWORD=SomethingLong123
RF_DB_ROOT_PASSWORD=AnotherLongOne456
```

With these settings, `rfctl up` does the following:

- Starts MySQL. Its data is stored in the Docker volume `<project>_mysql-data`.
- Runs `00_create_rf2232.sql` to create the three databases. Init renames the stock
  database names in the SQL files to your `RF_DB_*` names, the same rewrite the upstream
  provisioning does.
- Creates `RF_DB_USER` and grants it the three databases.
- Applies the accounts schema (`01`, `19`) if the `accounts` table is missing, and the
  game schema (`12`, `16`, `17`, `18`, `25`) if `schema_info` is missing. A database
  that already has a schema is left alone. All files use `CREATE TABLE IF NOT EXISTS`.
- On its first start, the gameserver imports `db/gamedata_rf2232.db` into the gamedata
  database: about 2.7M rows, roughly 1–2 minutes. **Don't stop it during the import.**
  An interrupted import leaves a partly filled database, and the server refuses to
  re-import into it. If that happens, run `./rfctl reset-gamedata`.

To use your own MySQL server instead, set `RF_MYSQL_BUNDLED=0` and `RF_DB_HOST`. If you
leave `RF_DB_ROOT_PASSWORD` empty, init does everything as `RF_DB_USER`, which then
needs privileges to create databases.

Password limits: `settings.cfg` values end at the first whitespace, and `#` and `//`
start comments. `rfctl` rejects DB passwords that contain any of these.

Switching between SQLite and MySQL does not move any data.

## Schema tracking

This server has **no `migrations` table**. Upstream policy is "wipe and reseed": the
server only provisions an empty database. Two tables record the schema state, and
`./rfctl check-db` reports both of them. `rfctl up` and `rfctl status` also run this
check.

- `gommo_rf2232.schema_info`: the game schema version, a single row (`id=1`) with the
  version number and when it was applied.
- `gamedata_rf2232._import_manifest`: one row per imported content table (171 in this
  release).

```
Database provider: sqlite
  gommo_accounts         12 tables  (168K)
  gommo_rf2232           52 tables  (648K)
  gamedata_rf2232       206 tables  (181M)

Schema tracking (this server has no 'migrations' table; it uses these):
  gommo_rf2232.schema_info         : version 1 (applied 2026-10-04 15:35:34)
  gamedata_rf2232._import_manifest : 171 content tables imported
```

## Backups

Backups go to `data/backups/<YYYY-MM-DD_HHMMSS>_<label>/`, with a `backup.json` in the
same format GoMMO Manager writes. The control panel's backup status reads them.

- SQLite: an online copy through SQLite's backup API, safe while the server runs.
- MySQL: `mariadb-dump --single-transaction` per database, saved as `<db>.sql.gz`.
- The game content DB is included by default (`RF_BACKUP_GAMEDATA=1`), so edits made in
  the game-data editor are kept. It is about 180 MB per SQLite backup.

The `backup` service takes a backup every `RF_BACKUP_EVERY_HOURS` hours. `0` turns
automatic backups off. It keeps the newest `RF_BACKUP_KEEP` automatic (`_scheduled`)
backups. Manual, pre-restore and pre-import backups are never rotated, so delete those
yourself.

```bash
./rfctl backup                    # manual backup now (label "manual")
./rfctl backup before-event       # with a label
./rfctl backups                   # list
./rfctl restore 2026-10-10_101532_before-event
./rfctl prune                     # apply RF_BACKUP_KEEP now
```

`restore` stops the servers. It then takes a `pre-restore` safety backup, replaces the
databases and starts the servers again. SQLite backups restore only on SQLite, and MySQL
backups only on MySQL.

For off-site copies, sync `data/backups/` with any tool (rsync, restic, rclone). On
SQLite, copying the whole `data/` folder while the stack is stopped is also a complete
backup.

## Day-to-day commands

```bash
./rfctl status                 # containers and DB schema state
./rfctl logs gameserver -f     # follow logs (gameserver | webserver | backup | init | mysql)
./rfctl restart                # apply .env changes
./rfctl stop | down            # stop / remove containers (data is kept)
./rfctl super-password         # show the one-time admin bootstrap password, if any
./rfctl shell                  # tools container: sqlite3, mariadb clients, rf-tools
./rfctl rfassets /path/to/RF   # build the website's item art from your RF client
./rfctl reset-gamedata         # rebuild the content DB from the stock copy
```

Set `ASSUME_YES=1` to skip confirmation prompts (for scripts or cron).

Logs: container output is rotated (`RF_LOG_MAX_SIZE`, `RF_LOG_MAX_FILES`). The gameserver
also writes `data/logs/history*.log`, starting a new file on each start. Clean those up
from time to time.

## HTTPS

Set `RF_TLS_DOMAIN=rf.example.com`. The name must point to this host, and ports 80 and
443 must be reachable from the internet. `rfctl` then adds `docker-compose.tls.yml`,
which publishes 80/443 and starts the webserver without `-http`. The webserver gets
and renews its Let's Encrypt certificate itself.

`HOME` points to `data/settings/.home` so that the certificate cache persists. After the
first certificate is issued, run `docker diff <project>-webserver-1`. If it shows a new
directory outside the mounted folders, mount that path as well. Otherwise every restart
requests a new certificate, and you can hit Let's Encrypt rate limits.

## Images

| Image | Base | Size (compressed) | Contents |
|---|---|---|---|
| `rf2232-gameserver` | scratch | ~9 MB | static `gameserver`, `data/`, `scripts/`, CA roots, zoneinfo |
| `rf2232-webserver` | scratch | ~8 MB | static `webserver` (the site is embedded), CA roots, zoneinfo |
| `rf2232-tools` | alpine | ~54 MB | bash, sqlite3, mariadb client, `rfassets`, `manifgen`, MySQL schema, stock content DB (gzipped) |

The build reads only the files it copies from the bundle. `client/`, `client-gommo/`,
`backups/`, `logs/`, the Windows binaries and your live databases are never sent to
Docker. The website serves the launcher from `data/client`, which init copies from the
read-only mount `RF_CLIENT_SRC` (default `<bundle>/client`).

The servers run as `RF_UID:RF_GID`, not as root. On Linux, the webserver can bind ports
80/443 because the gameserver container sets `net.ipv4.ip_unprivileged_port_start=0`.

Customising content: `data/custom/data/maps/*.json` overrides map placements, as the
gameserver reports at start. Legacy or client game-data modes read from `data/custom/`
when `RF_LEGACY_PATH` / `RF_CLIENT_PATH` point there, for example
`custom/gamedata-legacy`. To change the dungeon Lua scripts, mount your own folder over
`/opt/rf2232/scripts` in a `docker-compose.override.yml`.

## Upgrading to a new bundle

1. Unpack the new release next to this folder and point `RF_BUNDLE_DIR` at it. Bump
   `RF_IMAGE_TAG`.
2. Run `./rfctl backup pre-upgrade`, then `./rfctl build` and `./rfctl restart`.
3. Existing databases are kept, because the server never changes a populated database.
   To take the new release's content, run `./rfctl reset-gamedata`. Edits made in the
   game-data editor are lost. Read the upstream changelog to see whether the game schema
   changed and needs a reseed.

## Without rfctl

Plain Compose also works: `docker compose up -d` (add `--profile mysql` for MySQL, and
`-f docker-compose.yml -f docker-compose.tls.yml` for HTTPS). One-off tools commands:
`docker compose run --rm --no-deps init <check-db|backup|list|restore NAME|reset-gamedata>`.
If you change `RF_SERVICE_PORT`, also export `RF_LAUNCHER_PORT` set to that port plus 1.
If you recreate the gameserver container, restart the webserver too, because it shares
the gameserver's network.
