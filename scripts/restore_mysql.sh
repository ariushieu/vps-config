#!/bin/bash
# ============================================================
# restore_mysql.sh - Safe MySQL restore helper for Docker
# Description: Restores a MySQL dump only after rejecting SQL
#              that can overwrite Docker-created users/passwords.
#
# Usage:
#   sudo bash restore_mysql.sh <dump.sql.gz|dump.sql> <mysql-container>
#
# Example:
#   sudo bash scripts/restore_mysql.sh \
#     /opt/backups/my-app/mysql/my-app_mysql_2026-04-15_02-00-00.sql.gz \
#     my-app-mysql
# ============================================================

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }

usage() {
    echo "Usage: sudo bash $0 <dump.sql.gz|dump.sql> <mysql-container>"
}

stream_dump() {
    local dump_file="$1"

    case "$dump_file" in
        *.gz)
            gzip -cd "$dump_file"
            ;;
        *)
            cat "$dump_file"
            ;;
    esac
}

validate_dump_file() {
    local dump_file="$1"

    if [[ ! -f "$dump_file" ]]; then
        log_error "Dump file not found: $dump_file"
        return 1
    fi

    if [[ ! -s "$dump_file" ]]; then
        log_error "Dump file is empty: $dump_file"
        return 1
    fi

    if [[ "$dump_file" == *.gz ]] && ! gzip -t "$dump_file" 2>/dev/null; then
        log_error "Dump gzip integrity check failed: $dump_file"
        return 1
    fi
}

validate_safe_mysql_dump() {
    local dump_file="$1"

    local forbidden_pattern='USE[[:space:]]+`?(mysql|information_schema|performance_schema|sys)`?[[:space:]]*;|CREATE[[:space:]]+(DATABASE|SCHEMA)[^;]*`(mysql|information_schema|performance_schema|sys)`|CREATE[[:space:]]+(DATABASE|SCHEMA)[^;]*[[:space:]](mysql|information_schema|performance_schema|sys)[[:space:];]|DROP[[:space:]]+(DATABASE|SCHEMA)[[:space:]]+`?(mysql|information_schema|performance_schema|sys)`?([[:space:];]|$)|((INSERT[[:space:]]+INTO|REPLACE[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+`?mysql`?\.)|(^|;)[[:space:]]*(CREATE|ALTER|DROP)[[:space:]]+USER[[:space:]]|(^|;)[[:space:]]*(GRANT|REVOKE)[[:space:]]'

    if stream_dump "$dump_file" | grep -Ei "$forbidden_pattern" >/dev/null; then
        log_error "Unsafe dump rejected: contains MySQL system schema or user/privilege statements"
        log_error "Do not restore dumps made with --all-databases into a new container."
        return 1
    fi
}

validate_container() {
    local container="$1"

    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_error "Container not found: $container"
        return 1
    fi

    if ! docker exec "$container" bash -c 'test -n "${MYSQL_ROOT_PASSWORD:-}"' >/dev/null 2>&1; then
        log_error "MYSQL_ROOT_PASSWORD is not available inside container: $container"
        return 1
    fi
}

restore_mysql_dump() {
    local dump_file="$1"
    local container="$2"

    log_warn "Restoring $dump_file into container $container"
    log_warn "This can overwrite application tables in the target database."

    if ! stream_dump "$dump_file" | docker exec -i "$container" bash -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD"'; then
        log_error "MySQL restore failed"
        return 1
    fi

    log_info "MySQL restore completed"
}

main() {
    if [[ $# -ne 2 ]]; then
        usage
        exit 1
    fi

    local dump_file="$1"
    local container="$2"

    validate_dump_file "$dump_file"
    validate_safe_mysql_dump "$dump_file"
    validate_container "$container"
    restore_mysql_dump "$dump_file" "$container"
}

main "$@"
