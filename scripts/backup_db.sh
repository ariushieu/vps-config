#!/bin/bash
# ============================================================
# backup_db.sh - Automated Database Backup Script
# Description: Backup MySQL and MongoDB databases from Docker
#              containers. Designed to run via cron.
#
# Usage:
#   sudo bash backup_db.sh [REPO_DIR]
#   REPO_DIR: path to vps-config repo (default: ~/vps-config)
#
# Cron example (daily at 2:00 AM):
#   0 2 * * * /root/vps-config/scripts/backup_db.sh >> /var/log/backup_db.log 2>&1
# ============================================================

set -euo pipefail

REPO_DIR="${1:-$HOME/vps-config}"
BACKUP_ROOT="/opt/backups"
KEEP_DAYS=7
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# -----------------------------------------------------------
# Color & Log helpers
# -----------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# -----------------------------------------------------------
# Backup MySQL container
# -----------------------------------------------------------
backup_mysql() {
    local container="$1"
    local project="$2"
    local backup_dir="$BACKUP_ROOT/$project/mysql"

    mkdir -p "$backup_dir"

    local dump_file="$backup_dir/${project}_mysql_${DATE}.sql.gz"

    log_info "[$project] Backing up MySQL ($container) ..."
    # Run mysqldump inside container using its own env var — password never leaks to host ps aux
    docker exec "$container" bash -c \
        'mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --routines --triggers 2>/dev/null' \
        | gzip > "$dump_file"

    # Verify backup integrity
    if ! gzip -t "$dump_file" 2>/dev/null; then
        log_error "[$project] Backup corrupted: $dump_file"
        rm -f "$dump_file"
        return 1
    fi

    local size
    size=$(du -sh "$dump_file" | cut -f1)
    log_info "[$project] MySQL backup done: $dump_file ($size) [verified]"
}

# -----------------------------------------------------------
# Backup MongoDB container
# -----------------------------------------------------------
backup_mongo() {
    local container="$1"
    local project="$2"
    local backup_dir="$BACKUP_ROOT/$project/mongo"

    mkdir -p "$backup_dir"

    local dump_dir="$backup_dir/${project}_mongo_${DATE}"

    log_info "[$project] Backing up MongoDB ($container) ..."

    # Run mongodump inside container using its own env vars — credentials never leak to host
    docker exec "$container" bash -c '
        if [ -n "$MONGO_INITDB_ROOT_USERNAME" ] && [ -n "$MONGO_INITDB_ROOT_PASSWORD" ]; then
            mongodump --username="$MONGO_INITDB_ROOT_USERNAME" --password="$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase=admin --out=/tmp/mongodump 2>/dev/null
        else
            mongodump --out=/tmp/mongodump 2>/dev/null
        fi
    '

    # Copy dump from container to host and compress
    docker cp "$container":/tmp/mongodump "$dump_dir"
    docker exec "$container" rm -rf /tmp/mongodump

    tar -czf "${dump_dir}.tar.gz" -C "$backup_dir" "$(basename "$dump_dir")"
    rm -rf "$dump_dir"

    # Verify backup integrity
    if ! tar -tzf "${dump_dir}.tar.gz" &>/dev/null; then
        log_error "[$project] Backup corrupted: ${dump_dir}.tar.gz"
        rm -f "${dump_dir}.tar.gz"
        return 1
    fi

    local size
    size=$(du -sh "${dump_dir}.tar.gz" | cut -f1)
    log_info "[$project] MongoDB backup done: ${dump_dir}.tar.gz ($size) [verified]"
}

# -----------------------------------------------------------
# Cleanup old backups (keep last N days)
# -----------------------------------------------------------
cleanup_old_backups() {
    log_info "Cleaning up backups older than $KEEP_DAYS days..."

    find "$BACKUP_ROOT" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
        -mtime +$KEEP_DAYS -delete 2>/dev/null || true

    # Remove empty directories
    find "$BACKUP_ROOT" -type d -empty -delete 2>/dev/null || true

    log_info "Cleanup done."
}

# -----------------------------------------------------------
# Detect Compose-owned database containers
# -----------------------------------------------------------
container_belongs_to_project() {
    local container="$1"
    local project_name="$2"
    local project_dir="$3"
    local compose_file="$4"

    if grep -qF "$container" "$compose_file" 2>/dev/null; then
        return 0
    fi

    local label_project label_working_dir label_config_files
    label_project=$(docker inspect "$container" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
    label_working_dir=$(docker inspect "$container" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)
    label_config_files=$(docker inspect "$container" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)

    if [[ "$label_project" == "$project_name" ]]; then
        return 0
    fi

    if [[ -n "$label_working_dir" && "$label_working_dir" != "<no value>" ]]; then
        local project_real label_working_real
        project_real=$(realpath "$project_dir" 2>/dev/null || echo "${project_dir%/}")
        label_working_real=$(realpath "$label_working_dir" 2>/dev/null || echo "${label_working_dir%/}")
        if [[ "$label_working_real" == "$project_real" ]]; then
            return 0
        fi
    fi

    if [[ -n "$label_config_files" && "$label_config_files" != "<no value>" && "$label_config_files" == *"$compose_file"* ]]; then
        return 0
    fi

    return 1
}

detect_db_containers() {
    local project_name="$1"
    local project_dir="$2"
    local compose_file="$3"
    local image_pattern="$4"

    docker ps --format '{{.Names}}' | while read -r name; do
        local image
        image=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)
        if [[ "$image" == *"$image_pattern"* ]] && container_belongs_to_project "$name" "$project_name" "$project_dir" "$compose_file"; then
            echo "$name"
        fi
    done | sort -u
}

# -----------------------------------------------------------
# Scan projects and run backups
# -----------------------------------------------------------
run_backups() {
    local PROJECTS_DIR="$REPO_DIR/projects"

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        log_error "Projects directory not found: $PROJECTS_DIR"
        exit 1
    fi

    mkdir -p "$BACKUP_ROOT"

    local backup_count=0

    for project_dir in "$PROJECTS_DIR"/*/; do
        local project_name
        project_name=$(basename "$project_dir")

        # Skip example templates
        if [[ "$project_name" == example-* ]]; then
            continue
        fi

        local compose_file="$project_dir/docker-compose.yml"
        if [[ ! -f "$compose_file" ]]; then
            continue
        fi

        # Detect MySQL containers
        local mysql_containers
        mysql_containers=$(detect_db_containers "$project_name" "$project_dir" "$compose_file" "mysql" || true)

        for container in $mysql_containers; do
            backup_mysql "$container" "$project_name" && ((backup_count++)) || true
        done

        # Detect MongoDB containers
        local mongo_containers
        mongo_containers=$(detect_db_containers "$project_name" "$project_dir" "$compose_file" "mongo" || true)

        for container in $mongo_containers; do
            backup_mongo "$container" "$project_name" && ((backup_count++)) || true
        done
    done

    if [[ $backup_count -eq 0 ]]; then
        log_warn "No databases found to backup. Are containers running?"
    else
        log_info "Total backups completed: $backup_count"
    fi
}

# -----------------------------------------------------------
# MAIN
# -----------------------------------------------------------
main() {
    log_info "========== Database Backup Started =========="
    log_info "Repo: $REPO_DIR | Backup dir: $BACKUP_ROOT | Keep: ${KEEP_DAYS} days"
    echo ""

    run_backups
    cleanup_old_backups

    echo ""
    log_info "========== Database Backup Finished =========="

    # Show backup disk usage
    if [[ -d "$BACKUP_ROOT" ]]; then
        log_info "Backup storage usage:"
        du -sh "$BACKUP_ROOT"/* 2>/dev/null || log_info "  (empty)"
    fi
}

main "$@"
