#!/bin/bash
# ============================================================
# restore_mongo.sh - Safe MongoDB restore helper for Docker
# Description: Restores a MongoDB tar.gz dump only after
#              rejecting system databases.
#
# Usage:
#   sudo bash restore_mongo.sh [--yes] [--force] <dump.tar.gz> <mongo-container>
#
# Flags:
#   --yes    Skip the interactive confirmation prompt (for scripted use).
#   --force  Skip the system-database scan (only when you fully trust the dump).
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
    echo "Usage: sudo bash $0 [--yes] [--force] <dump.tar.gz> <mongo-container>"
}

confirm_restore() {
    local dump_file="$1"
    local container="$2"

    log_warn "About to restore MongoDB dump with --drop:"
    log_warn "  Dump file: $dump_file"
    log_warn "  Target container: $container"
    log_warn "Every collection in the target databases will be dropped before restore."

    local reply
    read -r -p "Type 'yes' to continue: " reply
    if [[ "$reply" != "yes" ]]; then
        log_error "Aborted by user."
        exit 1
    fi
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

    if ! tar -tzf "$dump_file" >/dev/null 2>&1; then
        log_error "Dump tar.gz integrity check failed: $dump_file"
        return 1
    fi
}

validate_archive_paths() {
    local dump_file="$1"

    if tar -tzf "$dump_file" | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
        log_error "Unsafe dump rejected: archive contains absolute or parent-relative paths"
        return 1
    fi
}

validate_safe_mongo_dump() {
    local extract_dir="$1"

    if find "$extract_dir" -mindepth 1 -maxdepth 3 -type d \( -name admin -o -name config -o -name local \) | grep . >/dev/null; then
        log_error "Unsafe dump rejected: contains MongoDB system database directories"
        log_error "Do not restore legacy all-database MongoDB dumps into a new container."
        return 1
    fi
}

validate_container() {
    local container="$1"

    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_error "Container not found: $container"
        return 1
    fi
}

resolve_restore_root() {
    local extract_dir="$1"
    local top_level_dirs=()
    local dir

    while IFS= read -r -d '' dir; do
        top_level_dirs+=("$dir")
    done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -print0)

    if [[ ${#top_level_dirs[@]} -eq 1 ]]; then
        printf "%s" "${top_level_dirs[0]}"
    else
        printf "%s" "$extract_dir"
    fi
}

restore_mongo_dump() {
    local restore_root="$1"
    local container="$2"

    log_warn "Restoring MongoDB dump into container $container"
    log_warn "This can overwrite application collections in the target database."

    docker exec "$container" rm -rf /tmp/mongorestore 2>/dev/null || true

    if ! docker cp "$restore_root"/. "$container":/tmp/mongorestore; then
        log_error "Could not copy MongoDB dump into container: $container"
        return 1
    fi

    if ! docker exec "$container" bash -c '
        if [ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ] && [ -n "${MONGO_INITDB_ROOT_PASSWORD:-}" ]; then
            mongorestore --username="$MONGO_INITDB_ROOT_USERNAME" --password="$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase=admin --drop /tmp/mongorestore
        else
            mongorestore --drop /tmp/mongorestore
        fi
    '; then
        docker exec "$container" rm -rf /tmp/mongorestore 2>/dev/null || true
        log_error "MongoDB restore failed"
        return 1
    fi

    docker exec "$container" rm -rf /tmp/mongorestore 2>/dev/null || true
    log_info "MongoDB restore completed"
}

main() {
    local assume_yes=0
    local force=0
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)
                assume_yes=1
                shift
                ;;
            --force)
                force=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    positional+=("$1")
                    shift
                done
                ;;
            -*)
                log_error "Unknown flag: $1"
                usage
                exit 1
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -ne 2 ]]; then
        usage
        exit 1
    fi

    local dump_file="${positional[0]}"
    local container="${positional[1]}"
    local temp_dir
    local restore_root

    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    validate_dump_file "$dump_file"
    validate_archive_paths "$dump_file"
    validate_container "$container"

    tar -xzf "$dump_file" -C "$temp_dir"

    if [[ $force -eq 1 ]]; then
        log_warn "--force set; skipping system-database scan on dump"
    else
        validate_safe_mongo_dump "$temp_dir"
    fi

    restore_root=$(resolve_restore_root "$temp_dir")

    if [[ $assume_yes -ne 1 ]]; then
        confirm_restore "$dump_file" "$container"
    fi

    restore_mongo_dump "$restore_root" "$container"
}

main "$@"
