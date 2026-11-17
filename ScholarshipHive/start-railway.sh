#!/bin/sh
set -e

VOLUME_DIR="${RAILWAY_VOLUME_MOUNT_PATH:-}"
if [ -z "$VOLUME_DIR" ] && [ -d "/data" ]; then
    VOLUME_DIR="/data"
fi

# Persistent file storage if volume is mounted
if [ -n "$VOLUME_DIR" ] && [ -d "$VOLUME_DIR" ]; then
    mkdir -p "$VOLUME_DIR/files"
    export STORAGE_DIR="$VOLUME_DIR/files"
fi

# If no external MYSQLHOST is configured, run embedded MariaDB inside container
if [ -z "${MYSQLHOST:-}" ] && [ -z "${DB_HOST:-}" ]; then
    DB_DATA_DIR="/var/lib/mysql"
    if [ -n "$VOLUME_DIR" ] && [ -d "$VOLUME_DIR" ]; then
        DB_DATA_DIR="$VOLUME_DIR/mysql"
    fi
    DB_SOCKET="/run/mysqld/mysqld.sock"

    # Application DB password: prefer a Railway env var, fall back to the legacy
    # default so existing data directories keep working. Never printed to logs.
    EMBED_DB_PASS="${MARIADB_PORTAL_PASSWORD:-${MYSQLPASSWORD:-${DB_PASS:-portal123}}}"

    mkdir -p "$DB_DATA_DIR" /run/mysqld
    chown -R mysql:mysql "$DB_DATA_DIR" /run/mysqld

    if [ ! -d "$DB_DATA_DIR/mysql" ]; then
        echo "[Railway Init] Initializing embedded MariaDB data directory at $DB_DATA_DIR..."
        mariadb-install-db --user=mysql --datadir="$DB_DATA_DIR" --auth-root-authentication-method=socket --skip-test-db >/dev/null
    fi

    echo "[Railway Init] Starting embedded MariaDB server..."
    mariadbd --user=mysql --datadir="$DB_DATA_DIR" --socket="$DB_SOCKET" --bind-address=127.0.0.1 --port=3306 --skip-networking=0 &

    # Wait for the server to accept connections over its local socket.
    DB_READY=0
    for _ in $(seq 1 60); do
        if mariadb-admin --socket="$DB_SOCKET" ping >/dev/null 2>&1; then
            DB_READY=1
            break
        fi
        sleep 1
    done
    if [ "$DB_READY" -ne 1 ]; then
        echo "[Railway Init] ERROR: embedded MariaDB did not become ready in time." >&2
        exit 1
    fi

    # Privileged bootstrap runs over the Unix socket as the mysql OS user, which is
    # how the initial root account authenticates (unix_socket, NOT a password / TCP).
    # Connecting as root over TCP is what triggers "ERROR 1698 Access denied for
    # user 'root'@'localhost'", so we deliberately use the socket here. This is
    # idempotent (IF NOT EXISTS) and safe to re-run on an existing data directory.
    # ALTER USER keeps the password in sync if it is rotated via the env var.
    if ! mariadb --socket="$DB_SOCKET" -u root <<SQL
CREATE DATABASE IF NOT EXISTS portal CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'portal'@'%' IDENTIFIED BY '${EMBED_DB_PASS}';
CREATE USER IF NOT EXISTS 'portal'@'localhost' IDENTIFIED BY '${EMBED_DB_PASS}';
ALTER USER 'portal'@'%' IDENTIFIED BY '${EMBED_DB_PASS}';
ALTER USER 'portal'@'localhost' IDENTIFIED BY '${EMBED_DB_PASS}';
GRANT ALL PRIVILEGES ON portal.* TO 'portal'@'%';
GRANT ALL PRIVILEGES ON portal.* TO 'portal'@'localhost';
FLUSH PRIVILEGES;
SQL
    then
        echo "[Railway Init] ERROR: database bootstrap failed. See MariaDB log above." >&2
        exit 1
    fi

    export MYSQLHOST="127.0.0.1"
    export MYSQLPORT="3306"
    export MYSQLDATABASE="portal"
    export MYSQLUSER="portal"
    export MYSQLPASSWORD="$EMBED_DB_PASS"
fi

DB_H="${MYSQLHOST:-${DB_HOST:-127.0.0.1}}"
DB_P="${MYSQLPORT:-${DB_PORT:-3306}}"
DB_N="${MYSQLDATABASE:-${MYSQL_DATABASE:-${DB_NAME:-portal}}}"
DB_U="${MYSQLUSER:-${DB_USER:-portal}}"
DB_W="${MYSQLPASSWORD:-${DB_PASS:-portal123}}"

echo "[Railway Init] Waiting for MySQL at ${DB_H}:${DB_P}/${DB_N} (as application user)..."
APP_DB_READY=0
for _ in $(seq 1 60); do
    if mariadb --protocol=tcp --skip-ssl -h "$DB_H" -P "$DB_P" -u "$DB_U" -p"$DB_W" -e "SELECT 1" >/dev/null 2>&1; then
        APP_DB_READY=1
        break
    fi
    sleep 1
done
if [ "$APP_DB_READY" -ne 1 ]; then
    echo "[Railway Init] ERROR: could not connect to ${DB_H}:${DB_P} as '${DB_U}'. Check DB credentials/env." >&2
    exit 1
fi

# Seed database on first boot ONLY if the users table does not exist yet.
# This is the data-preservation guard: on every subsequent boot the table
# exists, so the seed import is skipped and existing records are untouched.
HAS_USERS=$(mariadb --protocol=tcp --skip-ssl -N -B -h "$DB_H" -P "$DB_P" -u "$DB_U" -p"$DB_W" "$DB_N" -e "SHOW TABLES LIKE 'users';" 2>/dev/null || true)
if [ -z "$HAS_USERS" ]; then
    echo "[Railway Init] Empty database detected — importing full v5 schema and seed data (369 students, 381 users)..."
    if mariadb --protocol=tcp --skip-ssl -h "$DB_H" -P "$DB_P" -u "$DB_U" -p"$DB_W" "$DB_N" < /app/database/railway_full_seed.sql; then
        echo "[Railway Init] Database seed complete!"
    else
        echo "[Railway Init] ERROR: seed import failed. Not starting app so the half-imported data can be inspected." >&2
        exit 1
    fi
else
    echo "[Railway Init] Existing database detected — skipping seed, preserving all data."
fi

php /app/database/migrate.php || true

PORT_NUM="${PORT:-8000}"
echo "[Railway Start] Starting ScholarshipHive Processing Portal on 0.0.0.0:${PORT_NUM}..."
exec php -d upload_max_filesize=20M -d post_max_size=22M -S "0.0.0.0:${PORT_NUM}" -t /app/portal /app/portal/router.php
