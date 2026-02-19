#!/usr/bin/env bash
# Author: Mohamed Bouzahir
set -euo pipefail

# Set colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'


log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

error() {
  log "${RED}ERROR:${RESET} $*" >&2
  exit 1
}

info() {
  log "${GREEN}INFO:${RESET} $*"
}

warn() {
  log "${YELLOW}WARNING:${RESET} $*"
}

# Function to delete old volumes
rm_docker_volume_if_exists() {
  local volume_name="$1"
  if docker volume inspect "$volume_name" >/dev/null 2>&1; then
    info "Removing docker volume: $volume_name"
    docker volume rm "$volume_name" >/dev/null
  else
    warn "Volume '$volume_name' does not exist; skipping."
  fi
}
# Function to create new volumes and set permissions
create_odoo_volumes() {
  local volumes=("$@")
  for volume in "${volumes[@]}"; do
    docker run --rm -it \
      -v "$volume":/var/lib/odoo \
      --user root \
      busybox sh -c "
        mkdir -p /var/lib/odoo/filestore
        mkdir -p /var/lib/odoo/sessions
        mkdir -p /var/lib/odoo/.local
        mkdir -p /var/lib/odoo/.cache
        chown -R 101:101 /var/lib/odoo
        chmod 700 /var/lib/odoo/sessions
        chmod 755 /var/lib/odoo
        find /var/lib/odoo -type d -exec chmod 755 {} \;
        find /var/lib/odoo -type f -exec chmod 644 {} \;
      "
  done
}
# Function to stop and remove existing containers
stop_and_remove_containers() {
  local container_names=("$@")
  for container in "${container_names[@]}"; do
    info "Stopping $container"
    docker compose down "$container"
  done
}

# Function to run OpenUpgrade migrations
run_openupgrade_migrations() {
  local version="$1"
  if [ -f "backups/backup_v$version.dump" ]; then
    info "Using backup file: backups/backup_v$version.dump"
    docker cp backups/backup_v$version.dump db:/tmp/backup_v$version.dump
    docker exec -i db pg_restore -U odoo -d db_odoo -c --if-exists --no-owner /tmp/backup_v$version.dump
  fi

  # Run OpenUpgrade migration from version $((version-1)) to version $version
  info "Running OpenUpgrade migration from version $((version-1)) to version $version"
  docker compose up upgrade$version --build 2>&1 | tee /tmp/upgrade$version.log
  if ! grep -q "Migration process completed" /tmp/upgrade$version.log; then
    error "Error: Migration $((version-1)) -> $version failed. 'Migration process completed' not found in logs."
  fi

  info "Dumping v$version database (custom format)..."
  docker exec db pg_dump -U odoo -d db_odoo -Fc -f /tmp/backup_v$version.dump
  docker cp db:/tmp/backup_v$version.dump backups/backup_v$version.dump
}

# Main script
info "Starting full upgrade process..."


rm_docker_volume_if_exists odoo-db-data
rm_docker_volume_if_exists odoo-data

create_odoo_volumes odoo-data odoo-db-data

stop_and_remove_containers odoov16 odoov17 odoov18


cd "$(dirname "$0")"
START_FROM=${1:-16}
echo "Starting full upgrade process from version $START_FROM..."
trap 'log "ERROR (exit=$?) at line $LINENO: $BASH_COMMAND"' ERR
# in terminal you can set BACKUP_ZIP env var to specify which backup zip to use, e.g.:
# BACKUP_ZIP="db_odoo_2026-01-15_11-03-11.zip"
BACKUP_ZIP="${BACKUP_ZIP:-db_odoo_2026-02-01_12-34-39.zip}"
BACKUP_DIR="backups"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_ZIP"
DB_NAME="${DB_NAME:-db_odoo}"


log "Stopping existing containers..."
docker compose down

# Running OpenUpgrade: 16 -> 17...
if [ "$START_FROM" -eq 16 ]; then

    if [[ ! -f "$BACKUP_PATH" ]]; then
    echo "Error: Backup zip '$BACKUP_PATH' not found." >&2
    exit 1
    fi

    log "Using backup file: $BACKUP_PATH"


    log "Cleaning extracted backup artifacts..."
    rm -fr backups/*.sql backups/filestore backups/manifest.json

    log "Unzipping backup into $BACKUP_DIR/..."
    unzip "$BACKUP_PATH" -d "$BACKUP_DIR"/

    log "Restoring filestore into odoo-data volume..."
    docker run --rm -v odoo-data:/var/lib/odoo -v "$(pwd)/backups/filestore:/backups/filestore:ro" busybox sh -c "mkdir -p /var/lib/odoo/filestore/db_odoo && cp -r /backups/filestore/* /var/lib/odoo/filestore/db_odoo/ && chown -R 101:101 /var/lib/odoo/filestore"

    log "Starting source database service (db)..."
    docker compose up -d db
    DB_SRC=$(docker compose ps -q db)
    # Wait until target DB is ready
    log "Waiting for database to be ready."
    until docker exec "$DB_SRC" pg_isready -U odoo >/dev/null 2>&1; do
    log "."
    sleep 1
    done

    log "Restoring database from backups/dump.sql (psql)..."
    # Restore with psql (dropping objects first, single transaction)
    docker cp backups/dump.sql "$DB_SRC":/tmp/dump.sql
    docker exec "$DB_SRC" psql -v ON_ERROR_STOP=1 -U odoo -d db_odoo -f /tmp/dump.sql

    ###### warning error here
    log "Applying Odoo 16 pre-migration SQL..."
    docker exec -i "$DB_SRC" psql -v ON_ERROR_STOP=0 -U odoo -d "$DB_NAME" < Odoo16/pre.sql
    cat Odoo16/pre.sql | docker exec -i "$DB_SRC" psql -v ON_ERROR_STOP=1 -U odoo -d "$DB_NAME"


    log "Starting Odoo v16 to update modules (stock, then all)..."
    docker compose up -d odoov16

    log "Stopping Odoo v16 container..."
    docker compose down odoov16
fi
if [ "$START_FROM" -le 16 ]; then
  log "Running OpenUpgrade: 16 -> 17..."
  docker compose up upgrade17 --build 2>&1 | tee /tmp/upgrade17.log
  if ! grep -q "Migration process completed" /tmp/upgrade17.log; then
    log "Error: Migration 16 -> 17 failed. 'Migration process completed' not found in logs."
    exit 1
  fi
  log "Dumping v17 database (custom format)..."
  docker exec "$DB_SRC" pg_dump -U odoo -d db_odoo -Fc -f /tmp/backup_v17.dump
  docker cp "$DB_SRC":/tmp/backup_v17.dump backups/backup_v17.dump
fi

# Running OpenUpgrade: 17 -> 18...
if [ "$START_FROM" -eq 17 ]; then
  # Restore with pg_restore (single transaction). Fresh DB: no need to clean.
  docker cp backups/backup_v17.dump "$DB_SRC":/tmp/backup_v17.dump
  docker exec "$DB_SRC" pg_restore -U odoo -d db_odoo -c --if-exists --no-owner /tmp/backup_v17.dump
fi
if [ "$START_FROM" -le 17 ]; then
  log "Running OpenUpgrade: 17 -> 18..."
  docker compose up upgrade18 --build 2>&1 | tee /tmp/upgrade18.log
  if ! grep -q "Migration process completed" /tmp/upgrade18.log; then
    log "Error: Migration 17 -> 18 failed. 'Migration process completed' not found in logs."
    exit 1
  fi
  log "Dumping v18 database (custom format)..."
  docker exec "$DB_SRC" pg_dump -U odoo -d db_odoo -Fc -f /tmp/backup_v18.dump
  docker cp "$DB_SRC":/tmp/backup_v18.dump backups/backup_v18.dump
fi


docker compose up odoov18 --build -d

# Update modules to handle dependencies and errors
log "Updating modules ..."
docker compose  run --rm odoov18 odoo -d db_odoo -u base --stop-after-init
# Get list of modules from custom-addons
# We use find to list directories, which correspond to modules
MODULES=$(find Upgrade18/custom-addons -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
for module in $MODULES; do
    log "Updating module: $module"
    docker compose run --rm odoov18 odoo -d db_odoo -u "$module" --stop-after-init
done
log "All modules updated."