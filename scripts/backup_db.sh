#!/bin/bash
# ============================================================
# backup_db.sh - Automated Database Backup Script
# Description: Backup MySQL and MongoDB databases from Docker
#              containers. Designed to run via cron.
#
# Usage:
#   sudo bash backup_db.sh [REPO_DIR]
#   REPO_DIR: path to vps-setup-kit repo (default: ~/vps-setup-kit)
#
# Cron example (daily at 2:00 AM):
#   0 2 * * * /bin/bash '/root/vps-setup-kit/scripts/backup_db.sh' '/root/vps-setup-kit' >> '/var/log/backup_db.log' 2>&1
# ============================================================

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
REPO_DIR="${1:-$HOME/vps-setup-kit}"
BACKUP_ROOT="/opt/backups"
KEEP_DAYS=7
DATE=$(date +%Y-%m-%d_%H-%M-%S)
LOCK_FILE="${BACKUP_LOCK_FILE:-/tmp/vps_backup_db.lock}"

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

acquire_backup_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        log_warn "flock not found; continuing without overlap protection"
        return 0
    fi

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_warn "Another backup is already running. Exiting."
        exit 0
    fi
}

is_system_mysql_schema() {
    local database="$1"

    case "$database" in
        mysql|information_schema|performance_schema|sys)
            return 0
            ;;
    esac

    return 1
}

validate_mysql_database_name() {
    local project="$1"
    local database="$2"

    if [[ -z "$database" ]]; then
        log_error "[$project] MYSQL_DATABASE is not set in container; refusing to dump all databases"
        return 1
    fi

    if is_system_mysql_schema "$database"; then
        log_error "[$project] Refusing to back up system schema: $database"
        return 1
    fi

    if [[ ! "$database" =~ ^[A-Za-z0-9_][A-Za-z0-9_\$-]*$ ]]; then
        log_error "[$project] Unsafe MYSQL_DATABASE value '$database'; use a plain schema name, not options or multiple schemas"
        return 1
    fi
}

validate_mysql_dump_scope() {
    local project="$1"
    local dump_file="$2"

    local forbidden_pattern='USE[[:space:]]+`?(mysql|information_schema|performance_schema|sys)`?[[:space:]]*;|CREATE[[:space:]]+(DATABASE|SCHEMA)[^;]*`(mysql|information_schema|performance_schema|sys)`|CREATE[[:space:]]+(DATABASE|SCHEMA)[^;]*[[:space:]](mysql|information_schema|performance_schema|sys)[[:space:];]|DROP[[:space:]]+(DATABASE|SCHEMA)[[:space:]]+`?(mysql|information_schema|performance_schema|sys)`?([[:space:];]|$)|((INSERT[[:space:]]+INTO|REPLACE[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+`?mysql`?\.)|(^|;)[[:space:]]*(CREATE|ALTER|DROP)[[:space:]]+USER[[:space:]]|(^|;)[[:space:]]*(GRANT|REVOKE)[[:space:]]'

    if gzip -cd "$dump_file" | grep -Ei "$forbidden_pattern" >/dev/null; then
        log_error "[$project] Backup contains MySQL system schema statements; deleting unsafe dump"
        return 1
    fi
}

is_system_mongo_database() {
    local database="$1"

    case "$database" in
        admin|config|local)
            return 0
            ;;
    esac

    return 1
}

validate_mongo_database_name() {
    local project="$1"
    local database="$2"

    if [[ -z "$database" ]]; then
        log_error "[$project] MONGO_INITDB_DATABASE is not set in container; refusing to dump all databases"
        return 1
    fi

    if is_system_mongo_database "$database"; then
        log_error "[$project] Refusing to back up MongoDB system database: $database"
        return 1
    fi

    if [[ ! "$database" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
        log_error "[$project] Unsafe MONGO_INITDB_DATABASE value '$database'; use a plain application database name"
        return 1
    fi
}

validate_mongo_dump_scope() {
    local project="$1"
    local dump_dir="$2"

    local system_database
    for system_database in admin config local; do
        if [[ -e "$dump_dir/$system_database" ]]; then
            log_error "[$project] MongoDB dump contains system database '$system_database'; deleting unsafe dump"
            return 1
        fi
    done
}

# -----------------------------------------------------------
# Backup MySQL container
# -----------------------------------------------------------
backup_mysql() {
    local container="$1"
    local project="$2"
    local backup_dir="$BACKUP_ROOT/$project/mysql"

    if ! mkdir -p "$backup_dir"; then
        log_error "[$project] Could not create backup directory: $backup_dir"
        return 1
    fi

    local dump_file="$backup_dir/${project}_mysql_${DATE}.sql.gz"
    local database

    if ! database=$(docker exec "$container" bash -c 'printf "%s" "${MYSQL_DATABASE:-}"'); then
        log_error "[$project] Could not read MYSQL_DATABASE from $container"
        return 1
    fi

    validate_mysql_database_name "$project" "$database" || return 1

    log_info "[$project] Backing up MySQL database '$database' ($container) ..."
    # Run mysqldump inside container using its own env var — password never leaks to host ps aux
    if ! docker exec "$container" bash -c \
        'mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --databases "$MYSQL_DATABASE" 2>/dev/null' \
        | gzip > "$dump_file"; then
        log_error "[$project] MySQL backup failed: $container/$database"
        rm -f "$dump_file"
        return 1
    fi

    # Verify backup integrity
    if ! gzip -t "$dump_file" 2>/dev/null; then
        log_error "[$project] Backup corrupted: $dump_file"
        rm -f "$dump_file"
        return 1
    fi

    if ! validate_mysql_dump_scope "$project" "$dump_file"; then
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

    if ! mkdir -p "$backup_dir"; then
        log_error "[$project] Could not create backup directory: $backup_dir"
        return 1
    fi

    local dump_dir="$backup_dir/${project}_mongo_${DATE}"
    local database

    if ! database=$(docker exec "$container" bash -c 'printf "%s" "${MONGO_INITDB_DATABASE:-}"'); then
        log_error "[$project] Could not read MONGO_INITDB_DATABASE from $container"
        return 1
    fi

    validate_mongo_database_name "$project" "$database" || return 1

    log_info "[$project] Backing up MongoDB database '$database' ($container) ..."

    # Run mongodump inside container using its own env vars — credentials never leak to host
    if ! docker exec "$container" bash -c '
        if [ -n "$MONGO_INITDB_ROOT_USERNAME" ] && [ -n "$MONGO_INITDB_ROOT_PASSWORD" ]; then
            mongodump --username="$MONGO_INITDB_ROOT_USERNAME" --password="$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase=admin --db="$MONGO_INITDB_DATABASE" --out=/tmp/mongodump 2>/dev/null
        else
            mongodump --db="$MONGO_INITDB_DATABASE" --out=/tmp/mongodump 2>/dev/null
        fi
    '; then
        log_error "[$project] MongoDB backup failed: $container/$database"
        docker exec "$container" rm -rf /tmp/mongodump 2>/dev/null || true
        return 1
    fi

    # Copy dump from container to host and compress
    if ! docker cp "$container":/tmp/mongodump "$dump_dir"; then
        log_error "[$project] Could not copy MongoDB dump from container: $container"
        docker exec "$container" rm -rf /tmp/mongodump 2>/dev/null || true
        rm -rf "$dump_dir"
        return 1
    fi

    docker exec "$container" rm -rf /tmp/mongodump 2>/dev/null || true

    if ! validate_mongo_dump_scope "$project" "$dump_dir"; then
        rm -rf "$dump_dir"
        return 1
    fi

    if ! tar -czf "${dump_dir}.tar.gz" -C "$backup_dir" "$(basename "$dump_dir")"; then
        log_error "[$project] Could not compress MongoDB dump: $dump_dir"
        rm -rf "$dump_dir" "${dump_dir}.tar.gz"
        return 1
    fi
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

    # Fallback: match the literal container_name: field in compose file.
    # We anchor the regex to the YAML key so arbitrary occurrences (image, service
    # name, networks) cannot false-match.
    if grep -Eq "^[[:space:]]*container_name:[[:space:]]*[\"']?${container}[\"']?[[:space:]]*$" "$compose_file" 2>/dev/null; then
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
            if backup_mysql "$container" "$project_name"; then
                ((backup_count+=1))
            fi
        done

        # Detect MongoDB containers
        local mongo_containers
        mongo_containers=$(detect_db_containers "$project_name" "$project_dir" "$compose_file" "mongo" || true)

        for container in $mongo_containers; do
            if backup_mongo "$container" "$project_name"; then
                ((backup_count+=1))
            fi
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
    acquire_backup_lock

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
