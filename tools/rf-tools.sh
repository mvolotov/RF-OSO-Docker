#!/usr/bin/env bash
# rf-tools - helper commands baked into the rf2232 "tools" image.
#
#   init                 prepare the data volume: settings.cfg from env, manager.ini,
#                        stock game content, launcher files, MySQL databases + schema
#   check-db             show which backend is in use and whether the schema tables
#                        (schema_info, _import_manifest) are present
#   backup [reason]      take one backup now (default reason: manual)
#   backup-loop          take a backup every RF_BACKUP_EVERY_HOURS, keep RF_BACKUP_KEEP
#   list                 list backups
#   restore <name>       restore a backup (game and web servers must be stopped)
#   prune                delete old automatic backups beyond RF_BACKUP_KEEP
#   reset-gamedata       rebuild the content database from the stock copy (servers stopped)
#   rfassets ...         run rfassets against this install (client mounted at /client)
#   wait-mysql           block until MySQL answers
#   shell                interactive bash
set -euo pipefail

ROOT=${RF_ROOT:-/opt/rf2232}
SEED=/opt/rf2232-seed
SETTINGS=$ROOT/settings/settings.cfg
MANAGER_INI=$ROOT/settings/manager.ini
DB_DIR=$ROOT/db
BACKUP_DIR=$ROOT/backups

RF_UID=${RF_UID:-1000}
RF_GID=${RF_GID:-1000}
PROVIDER=${RF_DB_PROVIDER:-sqlite}
DB_HOST=${RF_DB_HOST:-mysql}
DB_PORT=${RF_DB_PORT:-3306}
DB_USER=${RF_DB_USER:-root}
DB_PASSWORD=${RF_DB_PASSWORD:-}
DB_ROOT_PASSWORD=${RF_DB_ROOT_PASSWORD:-}
DB_ACCOUNTS=${RF_DB_ACCOUNTS:-gommo_accounts}
DB_GAME=${RF_DB_GAME:-gommo_rf2232}
DB_GAMEDATA=${RF_DB_GAMEDATA:-gamedata_rf2232}
BACKUP_EVERY_HOURS=${RF_BACKUP_EVERY_HOURS:-24}
BACKUP_KEEP=${RF_BACKUP_KEEP:-10}

log()  { printf '[rf-tools %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[rf-tools %s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[rf-tools %s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

case "$PROVIDER" in sqlite|mysql) ;; *) die "RF_DB_PROVIDER must be sqlite or mysql, got '$PROVIDER'";; esac

# ---------------------------------------------------------------------------
# MySQL helpers. Admin work (CREATE DATABASE, GRANT) uses root when a root
# password is given, otherwise the application account.
# ---------------------------------------------------------------------------
_mysql_cnf() { # $1 = user, $2 = password -> path of a client option file
  local f; f=$(mktemp)
  chmod 600 "$f"
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\nprotocol=tcp\nssl=0\n' \
    "$DB_HOST" "$DB_PORT" "$1" "${2//\"/\\\"}" > "$f"
  echo "$f"
}
APP_CNF=""; ADMIN_CNF=""
mysql_setup() {
  [ -n "$APP_CNF" ] && return
  APP_CNF=$(_mysql_cnf "$DB_USER" "$DB_PASSWORD")
  if [ -n "$DB_ROOT_PASSWORD" ]; then ADMIN_CNF=$(_mysql_cnf root "$DB_ROOT_PASSWORD"); else ADMIN_CNF=$APP_CNF; fi
  trap 'rm -f "$APP_CNF" "$ADMIN_CNF"' EXIT
}
my_app()   { mysql_setup; mariadb --defaults-extra-file="$APP_CNF" "$@"; }
my_admin() { mysql_setup; mariadb --defaults-extra-file="$ADMIN_CNF" "$@"; }
my_dump()  { mysql_setup; mariadb-dump --defaults-extra-file="$ADMIN_CNF" "$@"; }

wait_mysql() {
  local timeout=${1:-180} i=0
  log "waiting for MySQL at $DB_HOST:$DB_PORT ..."
  until my_admin -N -e 'SELECT 1' >/dev/null 2>&1; do
    i=$((i + 2)); [ "$i" -ge "$timeout" ] && { my_admin -e 'SELECT 1' || true; die "MySQL did not answer within ${timeout}s"; }
    sleep 2
  done
  log "MySQL is up ($(my_admin -N -e 'SELECT VERSION()'))"
}

mysql_table_count() { # $1 = database
  my_admin -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1'"
}
mysql_has_table() { # $1 = database, $2 = table
  [ "$(my_admin -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1' AND table_name='$2'")" != 0 ]
}

# The shipped .sql files name the stock databases; every provisioning path of
# the upstream project rewrites those names to the configured ones. Same here.
rewrite_sql() { # $1 = file
  sed -e "s/\bgommo_accounts\b/${DB_ACCOUNTS}/g" \
      -e "s/\bgommo_rf2232\b/${DB_GAME}/g" \
      -e "s/\bgamedata_rf2232\b/${DB_GAMEDATA}/g" "$1"
}

apply_sql_files() { # $1 = target database, $2.. = files
  local db=$1; shift
  local f
  for f in "$@"; do
    log "  applying $(basename "$f") -> $db"
    rewrite_sql "$f" | my_admin --default-character-set=utf8mb4 "$db"
  done
}

mysql_provision() {
  local sql=$SEED/database-mysql
  wait_mysql "${RF_MYSQL_WAIT:-180}"

  log "creating databases if missing: $DB_ACCOUNTS, $DB_GAME, $DB_GAMEDATA"
  rewrite_sql "$sql/00_create_rf2232.sql" | my_admin

  if [ -n "$DB_ROOT_PASSWORD" ] && [ "$DB_USER" != root ]; then
    log "granting $DB_USER access to the three databases"
    local pw=${DB_PASSWORD//\'/\'\'}
    my_admin -e "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$pw';
                 ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$pw';
                 GRANT ALL PRIVILEGES ON \`$DB_ACCOUNTS\`.* TO '$DB_USER'@'%';
                 GRANT ALL PRIVILEGES ON \`$DB_GAME\`.* TO '$DB_USER'@'%';
                 GRANT ALL PRIVILEGES ON \`$DB_GAMEDATA\`.* TO '$DB_USER'@'%';
                 FLUSH PRIVILEGES;"
  fi

  # Accounts database (shared by every GoMMO game on the box).
  if mysql_has_table "$DB_ACCOUNTS" accounts; then
    log "accounts schema present in $DB_ACCOUNTS ($(mysql_table_count "$DB_ACCOUNTS") tables) - left alone"
  else
    log "accounts schema missing in $DB_ACCOUNTS - applying"
    apply_sql_files "$DB_ACCOUNTS" "$sql/01_gommo_accounts.sql" "$sql/19_account_support_tickets.sql"
  fi

  # Game database. schema_info is the schema version marker (12_*.sql).
  if mysql_has_table "$DB_GAME" schema_info; then
    log "game schema present in $DB_GAME (schema_info v$(my_admin -N -e "SELECT schema_version FROM \`$DB_GAME\`.schema_info WHERE id=1")) - left alone"
  else
    log "game schema missing in $DB_GAME - applying"
    apply_sql_files "$DB_GAME" \
      "$sql/12_rf2232_game_tables.sql" \
      "$sql/16_rf2232_storelimit_game_tables.sql" \
      "$sql/17_rf2232_pvpkill_game_tables.sql" \
      "$sql/18_rf_news_game_tables.sql" \
      "$sql/25_rf_season_game_tables.sql"
  fi

  # Any extra files a newer bundle ships are applied too (all of them are
  # CREATE ... IF NOT EXISTS / INSERT IGNORE, so this is safe to repeat).
  local f known=" 00_create_rf2232.sql 01_gommo_accounts.sql 19_account_support_tickets.sql 12_rf2232_game_tables.sql 16_rf2232_storelimit_game_tables.sql 17_rf2232_pvpkill_game_tables.sql 18_rf_news_game_tables.sql 25_rf_season_game_tables.sql "
  for f in "$sql"/*.sql; do
    case "$known" in *" $(basename "$f") "*) continue;; esac
    if grep -q '^USE gommo_accounts;' "$f"; then apply_sql_files "$DB_ACCOUNTS" "$f"; else apply_sql_files "$DB_GAME" "$f"; fi
  done

  log "gamedata database $DB_GAMEDATA: $(mysql_table_count "$DB_GAMEDATA") tables (the gameserver imports db/gamedata_rf2232.db into it on first start)"
}

# ---------------------------------------------------------------------------
# settings.cfg / manager.ini
# ---------------------------------------------------------------------------
# set_cfg KEY VALUE - replace the "KEY<whitespace>value" line in settings.cfg.
set_cfg() {
  local key=$1 val=$2
  if grep -qE "^${key}([[:space:]]|$)" "$SETTINGS"; then
    K="$key" V="$val" awk '
      BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
      $0 ~ "^" k "([[:space:]]|$)" { print k "\t" v; next }
      { print }' "$SETTINGS" > "$SETTINGS.tmp" && cat "$SETTINGS.tmp" > "$SETTINGS" && rm -f "$SETTINGS.tmp"
  else
    warn "settings.cfg has no $key line; appending it"
    printf '%s\t%s\n' "$key" "$val" >> "$SETTINGS"
  fi
}

# Map of settings.cfg key -> environment variable. An env var that is not set
# leaves the line as it is; one that is set (even empty) wins.
CFG_MAP=(
  DEBUG:RF_DEBUG
  SERVICE_IP:RF_SERVICE_IP
  SERVICE_PORT:RF_SERVICE_PORT
  MAX_SESSIONS:RF_MAX_SESSIONS
  ALLOW_SCRIPTED_CLIENTS:RF_ALLOW_SCRIPTED_CLIENTS
  PROFILE_PORT:RF_PROFILE_PORT
  DATABASE_PROVIDER:RF_DB_PROVIDER
  DATABASE_HOST:RF_DB_HOST
  DATABASE_PORT:RF_DB_PORT
  DATABASE_USERNAME:RF_DB_USER
  DATABASE_PASSWORD:RF_DB_PASSWORD
  DATABASE_DSN_ACCOUNT:RF_DB_ACCOUNTS
  DATABASE_DSN_GAME:RF_DB_GAME
  DATABASE_DSN_GAMEDATA:RF_DB_GAMEDATA
  GAMEDATA_MODE:RF_GAMEDATA_MODE
  LEGACY_PATH:RF_LEGACY_PATH
  CLIENT_PATH:RF_CLIENT_PATH
  LEGACY_ZONES:RF_LEGACY_ZONES
  COOKIE_DOMAIN:RF_COOKIE_DOMAIN
  TLS_DOMAIN:RF_TLS_DOMAIN
  UPDATE_URL:RF_UPDATE_URL
  UPDATE_CHANNEL:RF_UPDATE_CHANNEL
)

render_settings() {
  if [ ! -f "$SETTINGS" ]; then
    log "settings.cfg not found - creating it from settings.cfg.example"
    cp "$SEED/settings.cfg.example" "$SETTINGS"
  fi
  local pair key var
  for pair in "${CFG_MAP[@]}"; do
    key=${pair%%:*}; var=${pair#*:}
    if [ -n "${!var+x}" ]; then set_cfg "$key" "${!var}"; fi
  done
  set_cfg DATABASE_PATH ./db   # fixed inside the container
  log "settings.cfg rendered (provider=$PROVIDER, port=$(awk '$1=="SERVICE_PORT"{print $2}' "$SETTINGS"))"

  # manager.ini: the webserver reads BACKUP_EVERY_HOURS / ports from it for the
  # control panel. GoMMO_Manager.exe (Windows only) is not used in containers.
  cat > "$MANAGER_INI" <<EOF
// Written by rf-tools init from the container environment - edit .env instead.
[manager]
GAME                rf2232
DISPLAY_NAME        RF Online: Golden Age
STATS_PORT          ${RF_STATS_PORT:-29913}
WEB_PORT            ${RF_WEB_PORT:-8080}
SERVICES            gameserver,webserver
BACKUP_EVERY_HOURS  ${BACKUP_EVERY_HOURS}
BACKUP_KEEP         ${BACKUP_KEEP}
AUTO_START          0
AUTO_RESTART        1
TRAY                0
EOF
}

seed_gamedata() {
  # db/ is the game content on BOTH backends (on MySQL the gameserver imports it).
  local target=$DB_DIR/gamedata_rf2232.db
  # On MySQL the gameserver renames the file to .backup once it has imported it.
  if [ "$PROVIDER" = mysql ] && [ -f "$target.backup" ]; then return 0; fi
  if [ ! -f "$target" ]; then
    log "installing the stock game content database -> db/gamedata_rf2232.db"
    gunzip -c "$SEED/db/gamedata_rf2232.db.gz" > "$target.tmp" && mv "$target.tmp" "$target"
  fi
  if [ "$PROVIDER" = sqlite ] && [ "$DB_GAMEDATA" != gamedata_rf2232 ] && [ ! -f "$DB_DIR/$DB_GAMEDATA.db" ]; then
    cp "$target" "$DB_DIR/$DB_GAMEDATA.db"
  fi
}

seed_client() {
  # The webserver serves client/ (launcher + launcher.ini) from its download
  # page. The client is NOT in any image; it is mounted read-only from the bundle
  # at /bundle-client and copied here so launcher.ini can carry the public host.
  local src=/bundle-client dst=$ROOT/client
  mkdir -p "$dst"
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
    cp -a "$src"/. "$dst"/
    if [ -f "$dst/launcher.ini" ]; then
      local port=${RF_SERVICE_PORT:-27800}
      H="${RF_PUBLIC_HOST:-}" GP="$port" AP="$((port + 1))" U="${RF_LAUNCHER_UPDATE_URL:-}" awk '
        BEGIN { h = ENVIRON["H"]; gp = ENVIRON["GP"]; ap = ENVIRON["AP"]; u = ENVIRON["U"] }
        h != "" && /^Host[[:space:]]*=/                  { print "Host         = " h; next }
        gp != 27800 && /^;?[[:space:]]*GamePort[[:space:]]*=/ { print "GamePort     = " gp; next }
        gp != 27800 && /^;?[[:space:]]*AuthPort[[:space:]]*=/ { print "AuthPort     = " ap; next }
        u != "" && /^URL[[:space:]]*=/                   { print "URL          = " u; next }
        { print }' "$dst/launcher.ini" > "$dst/launcher.ini.tmp" && mv "$dst/launcher.ini.tmp" "$dst/launcher.ini"
      log "client/launcher.ini: Host=${RF_PUBLIC_HOST:-<unchanged>} GamePort=$port AuthPort=$((port + 1)) URL=${RF_LAUNCHER_UPDATE_URL:-<unchanged>}"
    fi
  fi
}

cmd_init() {
  log "initialising $ROOT (provider: $PROVIDER)"
  # settings.cfg values end at the first whitespace, so the server would only
  # see part of such a password.
  case "$DB_PASSWORD" in *[[:space:]]*) die "RF_DB_PASSWORD must not contain spaces or tabs (settings.cfg cannot hold them)";; esac
  mkdir -p "$ROOT"/{settings,db,logs,backups,webassets,client,custom} "$ROOT/settings/.home/.cache"
  render_settings
  seed_gamedata
  seed_client
  if [ "$PROVIDER" = mysql ]; then mysql_provision; fi
  chown -R "$RF_UID:$RF_GID" "$ROOT"/{settings,db,logs,backups,webassets,client,custom}
  log "init done"
}

# ---------------------------------------------------------------------------
# check-db: report the schema state of every database
# ---------------------------------------------------------------------------
sqlite_q() { sqlite3 -batch -noheader "file:$1?mode=ro" "$2" 2>/dev/null; }

cmd_check_db() {
  local rc=0 f n v
  echo "Database provider: $PROVIDER"
  if [ "$PROVIDER" = sqlite ]; then
    for f in "$DB_ACCOUNTS" "$DB_GAME" "$DB_GAMEDATA"; do
      if [ -f "$DB_DIR/$f.db" ]; then
        n=$(sqlite_q "$DB_DIR/$f.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table'")
        printf '  %-20s %4s tables  (%s)\n' "$f" "$n" "$(du -h "$DB_DIR/$f.db" | cut -f1)"
      else
        printf '  %-20s MISSING (db/%s.db)\n' "$f" "$f"; rc=1
      fi
    done
    v=$(sqlite_q "$DB_DIR/$DB_GAME.db" "SELECT schema_version || ' (applied ' || applied_at || ')' FROM schema_info WHERE id=1" || true)
    n=$(sqlite_q "$DB_DIR/$DB_GAMEDATA.db" "SELECT COUNT(*) FROM _import_manifest" || true)
  else
    wait_mysql 30 2>/dev/null
    for f in "$DB_ACCOUNTS" "$DB_GAME" "$DB_GAMEDATA"; do
      printf '  %-20s %4s tables\n' "$f" "$(mysql_table_count "$f")"
    done
    v=$(my_admin -N -e "SELECT CONCAT(schema_version,' (applied ',applied_at,')') FROM \`$DB_GAME\`.schema_info WHERE id=1" 2>/dev/null || true)
    n=$(my_admin -N -e "SELECT COUNT(*) FROM \`$DB_GAMEDATA\`._import_manifest" 2>/dev/null || true)
  fi
  echo
  echo "Schema tracking (this server has no 'migrations' table; it uses these):"
  if [ -n "$v" ]; then echo "  $DB_GAME.schema_info         : version $v"; else echo "  $DB_GAME.schema_info         : NOT FOUND"; rc=1; fi
  if [ -n "$n" ]; then echo "  $DB_GAMEDATA._import_manifest : $n content tables imported"; else echo "  $DB_GAMEDATA._import_manifest : NOT FOUND (not imported yet?)"; rc=1; fi
  return $rc
}

# ---------------------------------------------------------------------------
# Backups. Layout and backup.json match what GoMMO Manager writes, so the
# control panel's backup status reads them:
#   backups/<YYYY-MM-DD_HHMMSS>_<reason>/{backup.json, <db>.db | <db>.sql.gz}
# ---------------------------------------------------------------------------
cmd_backup() {
  local reason=${1:-manual} stamp dir files=() f size first=1
  reason=$(printf '%s' "$reason" | tr -c 'A-Za-z0-9_-' '_')
  stamp=$(date +%Y-%m-%d_%H%M%S)
  dir=$BACKUP_DIR/${stamp}_${reason}
  mkdir -p "$dir"
  local dbs=("$DB_ACCOUNTS" "$DB_GAME")
  [ "${RF_BACKUP_GAMEDATA:-1}" = 1 ] && dbs+=("$DB_GAMEDATA")
  log "backup ($PROVIDER) -> backups/$(basename "$dir")"

  if [ "$PROVIDER" = sqlite ]; then
    for f in "${dbs[@]}"; do
      [ -f "$DB_DIR/$f.db" ] || { warn "db/$f.db not found, skipped"; continue; }
      # Online, consistent copy through SQLite's backup API (safe while the server runs).
      sqlite3 "$DB_DIR/$f.db" ".timeout 30000" ".backup '$dir/$f.db'"
      files+=("$f.db")
    done
  else
    wait_mysql 60 2>/dev/null
    for f in "${dbs[@]}"; do
      my_dump --single-transaction --quick --routines --triggers --events \
              --default-character-set=utf8mb4 --databases "$f" | gzip -6 > "$dir/$f.sql.gz"
      files+=("$f.sql.gz")
    done
  fi
  [ "${#files[@]}" -gt 0 ] || { rm -rf "$dir"; die "nothing was backed up"; }

  {
    printf '{\n  "time": "%s",\n  "reason": "%s",\n  "provider": "%s",\n  "files": [' \
      "$(date +%Y-%m-%dT%H:%M:%S%:z)" "$reason" "$PROVIDER"
    for f in "${files[@]}"; do
      size=$(stat -c %s "$dir/$f")
      [ $first = 1 ] || printf ','
      printf '\n    {\n      "name": "%s",\n      "size": %s\n    }' "$f" "$size"
      first=0
    done
    printf '\n  ]\n}\n'
  } > "$dir/backup.json"
  chown -R "$RF_UID:$RF_GID" "$dir" 2>/dev/null || true
  log "backup done: $(du -sh "$dir" | cut -f1)"
  echo "$(basename "$dir")"
}

cmd_prune() {
  # Only automatic backups are rotated; manual / pre-restore ones are kept.
  [ "$BACKUP_KEEP" -gt 0 ] 2>/dev/null || return 0
  local d
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '*_scheduled' -printf '%f\n' | sort -r \
    | tail -n +$((BACKUP_KEEP + 1)) | while read -r d; do
      log "pruning old backup $d"; rm -rf "${BACKUP_DIR:?}/$d"
    done
}

cmd_list() {
  local d j
  printf '%-36s %-10s %-8s %s\n' NAME PROVIDER SIZE FILES
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | while read -r d; do
    j=$BACKUP_DIR/$d/backup.json
    printf '%-36s %-10s %-8s %s\n' "$d" \
      "$( [ -f "$j" ] && sed -n 's/.*"provider": *"\([^"]*\)".*/\1/p' "$j" || echo '?')" \
      "$(du -sh "$BACKUP_DIR/$d" | cut -f1)" \
      "$(find "$BACKUP_DIR/$d" -maxdepth 1 -type f ! -name backup.json -printf '%f ' | tr -s ' ')"
  done
}

cmd_backup_loop() {
  local hours=$BACKUP_EVERY_HOURS period last now wait
  if ! [ "$hours" -gt 0 ] 2>/dev/null; then
    log "automatic backups are off (RF_BACKUP_EVERY_HOURS=$hours); idling"
    exec sleep infinity
  fi
  period=$((hours * 3600))
  log "automatic backups every ${hours}h, keeping $BACKUP_KEEP"
  # Give the gameserver a moment to provision/open its databases first.
  sleep "${RF_BACKUP_START_DELAY:-60}"
  if [ "${RF_BACKUP_ON_START:-0}" = 1 ]; then
    cmd_backup scheduled >/dev/null || warn "startup backup failed"
    cmd_prune
  fi
  while :; do
    # Schedule from the newest automatic backup so a restart does not reset the
    # clock; with none yet, the first one is taken now.
    last=$(find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -path '*_scheduled/backup.json' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    now=$(date +%s)
    wait=$(( ${last:-0} + period - now ))
    if [ "$wait" -gt 0 ]; then
      log "next backup in $((wait / 60)) min"
      sleep "$wait"
    fi
    cmd_backup scheduled >/dev/null || { warn "scheduled backup failed; retrying in 10 min"; sleep 600; continue; }
    cmd_prune
  done
}

cmd_restore() {
  local name=${1:-} dir f db
  [ -n "$name" ] || die "usage: restore <backup-name>  (see: list)"
  dir=$BACKUP_DIR/$name
  [ -d "$dir" ] || die "no such backup: $name"
  [ -f "$dir/backup.json" ] || warn "$name has no backup.json - restoring whatever it holds"

  if ls "$dir"/*.db >/dev/null 2>&1; then
    [ "$PROVIDER" = sqlite ] || die "$name is a SQLite backup but RF_DB_PROVIDER=$PROVIDER"
    log "safety backup of the current state first"
    cmd_backup pre-restore >/dev/null
    for f in "$dir"/*.db; do
      db=$(basename "$f")
      log "  restoring db/$db"
      rm -f "$DB_DIR/$db-wal" "$DB_DIR/$db-shm" "$DB_DIR/$db-journal"
      cp "$f" "$DB_DIR/$db.restore" && mv "$DB_DIR/$db.restore" "$DB_DIR/$db"
    done
    chown "$RF_UID:$RF_GID" "$DB_DIR"/*.db
  elif ls "$dir"/*.sql.gz >/dev/null 2>&1; then
    [ "$PROVIDER" = mysql ] || die "$name is a MySQL backup but RF_DB_PROVIDER=$PROVIDER"
    wait_mysql 60
    log "safety backup of the current state first"
    cmd_backup pre-restore >/dev/null
    for f in "$dir"/*.sql.gz; do
      db=$(basename "$f" .sql.gz)
      log "  restoring database $db"
      my_admin -e "DROP DATABASE IF EXISTS \`$db\`"
      gunzip -c "$f" | my_admin --default-character-set=utf8mb4
    done
  else
    die "$name holds neither .db nor .sql.gz files"
  fi
  log "restore of $name done"
}

cmd_reset_gamedata() {
  # Throws away the content database so the gameserver rebuilds it from the
  # stock copy on its next start. Needed after an interrupted first-start MySQL
  # import (the server refuses to import into a non-empty database) or to pick
  # up a new release's content. Operator edits made in the game-data editor are lost.
  log "safety backup of the current state first"
  cmd_backup pre-reset-gamedata >/dev/null
  if [ "$PROVIDER" = mysql ]; then
    wait_mysql 60
    log "recreating MySQL database $DB_GAMEDATA (empty; the gameserver re-imports it)"
    my_admin -e "DROP DATABASE IF EXISTS \`$DB_GAMEDATA\`; CREATE DATABASE \`$DB_GAMEDATA\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  fi
  log "replacing db/gamedata_rf2232.db with the stock copy from this image"
  rm -f "$DB_DIR"/gamedata_rf2232.db{,-wal,-shm,-journal,.backup}
  [ "$PROVIDER" = sqlite ] && [ "$DB_GAMEDATA" != gamedata_rf2232 ] && rm -f "$DB_DIR/$DB_GAMEDATA".db{,-wal,-shm,-journal}
  seed_gamedata
  chown "$RF_UID:$RF_GID" "$DB_DIR"/*.db
  log "done - start the gameserver and let it finish importing before stopping it"
}

cmd_rfassets() {
  [ -d /client ] || die "mount your RF client folder at /client (rfctl rfassets <path> does this)"
  rfassets -client /client -data-path "$ROOT" "$@"
  chown -R "$RF_UID:$RF_GID" "$ROOT/webassets" 2>/dev/null || true
}

cmd_help() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

cmd=${1:-help}; shift || true
case "$cmd" in
  init)          cmd_init "$@" ;;
  check-db)      cmd_check_db "$@" ;;
  backup)        cmd_backup "$@"; cmd_prune ;;
  backup-loop)   cmd_backup_loop ;;
  list)          cmd_list ;;
  restore)       cmd_restore "$@" ;;
  reset-gamedata) cmd_reset_gamedata ;;
  prune)         cmd_prune ;;
  rfassets)      cmd_rfassets "$@" ;;
  wait-mysql)    wait_mysql "${1:-180}" ;;
  shell|bash)    exec bash "$@" ;;
  help|-h|--help) cmd_help ;;
  *)             exec "$cmd" "$@" ;;
esac
