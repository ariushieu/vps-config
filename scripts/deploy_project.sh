#!/bin/bash
# ============================================================
# deploy_project.sh - Interactive Project Deployment
# Description: Create a new project from template, configure
#              domain, setup Nginx and auto-generate SSL.
#
# Usage: sudo bash deploy_project.sh [REPO_DIR]
# ============================================================

set -euo pipefail

# Default REPO_DIR to the repo this script lives in (see setup_vps.sh — the
# $HOME-based default broke under `sudo bash` from a non-root user's clone).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${1:-$(dirname "$SCRIPT_DIR")}"
PROJECTS_DIR="$REPO_DIR/projects"

# -----------------------------------------------------------
# Color & Log helpers
# -----------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${GREEN}========== $1 ==========${NC}\n"; }
prompt()      { echo -en "${CYAN}[?]${NC} $1"; }

# -----------------------------------------------------------
# 0. Check root + repo exists
# -----------------------------------------------------------
preflight() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root. Use: sudo bash deploy_project.sh"
        exit 1
    fi

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        log_error "Projects directory not found: $PROJECTS_DIR"
        log_error "Run setup_vps.sh first, then clone the repo."
        exit 1
    fi
}

# -----------------------------------------------------------
# 1. Ask project name
# -----------------------------------------------------------
ask_project_name() {
    echo ""
    prompt "Project name (e.g. mini-social-be, my-api): "
    read -r PROJECT_NAME

    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name cannot be empty."
        exit 1
    fi

    # Sanitize: lowercase, replace spaces with dashes
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    # Whitelist the result. PROJECT_NAME is later interpolated into rm -rf,
    # sed replacement strings, and a docker network name, so anything outside
    # [a-z0-9-] (especially '/', '..', '|', ';') is a path-traversal / injection
    # footgun. Reject rather than silently strip so the user picks a clean name.
    if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        log_error "Invalid project name: '$PROJECT_NAME'"
        log_error "Use lowercase letters, digits and dashes only (must start with a letter or digit)."
        exit 1
    fi

    PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

    if [[ -d "$PROJECT_DIR" ]]; then
        log_warn "Project '$PROJECT_NAME' already exists at $PROJECT_DIR"
        prompt "Overwrite? (y/N): "
        read -r OVERWRITE
        if [[ "$OVERWRITE" != "y" && "$OVERWRITE" != "Y" ]]; then
            log_info "Aborted."
            exit 0
        fi
        rm -rf "$PROJECT_DIR"
    fi

    log_info "Project name: $PROJECT_NAME"
}

# -----------------------------------------------------------
# 2. Ask domain
# -----------------------------------------------------------
ask_domain() {
    prompt "Domain for this project (e.g. api.qhieu.dev): "
    read -r DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        log_error "Domain cannot be empty."
        exit 1
    fi

    # DOMAIN is written verbatim into the generated nginx.conf (server_name,
    # ssl_certificate paths) and passed to certbot -d. Restrict it to a valid
    # hostname so a stray ';', '{', space, or newline can't inject an nginx
    # directive or an extra certbot argument.
    if [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid domain: '$DOMAIN'"
        log_error "Expected a hostname like api.example.com (letters, digits, dots, dashes)."
        exit 1
    fi

    log_info "Domain: $DOMAIN"

    # Verify DNS points to this server
    local server_ip
    server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
    # Resolve to A records only. `dig +short` on a CNAME prints the chased
    # hostname(s) before the final IP, so `tail -1` (the old approach) is right
    # only by luck; `dig A +short <name>` restricts output to IPv4 addresses.
    # We then check whether the server IP is among them (not just the last line).
    local domain_ips
    domain_ips=$(dig +short "$DOMAIN" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)

    if [[ -n "$domain_ips" ]] && grep -qxF "$server_ip" <<< "$domain_ips"; then
        log_info "DNS OK: $DOMAIN -> $server_ip"
    else
        local domain_ip
        domain_ip=$(tr '\n' ' ' <<< "${domain_ips:-unresolved}")
        log_warn "DNS mismatch: $DOMAIN -> ${domain_ip:-unresolved} (this server: $server_ip)"
        log_warn "Certbot may fail if DNS is not pointed to this server."
        prompt "Continue anyway? (y/N): "
        read -r CONTINUE
        if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
            log_info "Aborted. Point your DNS first, then re-run."
            exit 0
        fi
    fi
}

# -----------------------------------------------------------
# 3. Choose template
# -----------------------------------------------------------
choose_template() {
    echo ""
    log_info "Available templates:"
    echo ""

    local templates=()
    local i=1
    for tpl_dir in "$PROJECTS_DIR"/example-*/; do
        local tpl_name
        tpl_name=$(basename "$tpl_dir")
        templates+=("$tpl_name")
        echo "  $i) $tpl_name"
        ((i++))
    done

    if [[ ${#templates[@]} -eq 0 ]]; then
        log_error "No example-* templates found in $PROJECTS_DIR"
        exit 1
    fi

    echo ""
    prompt "Choose template [1-${#templates[@]}]: "
    read -r CHOICE

    if [[ -z "$CHOICE" ]] || [[ "$CHOICE" -lt 1 ]] || [[ "$CHOICE" -gt ${#templates[@]} ]]; then
        log_error "Invalid choice."
        exit 1
    fi

    TEMPLATE="${templates[$((CHOICE-1))]}"
    log_info "Template: $TEMPLATE"
}

# -----------------------------------------------------------
# 4. Detect app port from template & find next available
# -----------------------------------------------------------
detect_app_port() {
    local compose_tpl="$PROJECTS_DIR/$TEMPLATE/docker-compose.yml"
    # Extract the first host port from a published binding line: - "127.0.0.1:XXXX:YYYY".
    # The pattern is anchored to the YAML list item ('- "') so it can't match a
    # "127.0.0.1:3306" that merely appears inside a comment.
    local port_re='^\s*-\s*"?127\.0\.0\.1:\K\d+'
    local default_port
    default_port=$(grep -oP "$port_re" "$compose_tpl" | head -1 || echo "8080")

    # Find the next available port by scanning existing projects.
    # NOTE: this grep needs -P — the pattern uses PCRE (\K, \d). Previously it ran
    # with plain -ho, so \K matched nothing, used_ports was always empty, and the
    # auto-increment below never fired — every project reused the template's
    # default port and the 2nd same-stack project collided on 127.0.0.1:<port>.
    local used_ports
    used_ports=$(find "$PROJECTS_DIR" -name "docker-compose.yml" -not -path "*/example-*" -print0 | xargs -0 grep -hoP "$port_re" 2>/dev/null | sort -n | uniq || true)

    APP_PORT="$default_port"
    if [[ -n "$used_ports" ]]; then
        # If default port is taken, find the next available one
        if echo "$used_ports" | grep -q "^$APP_PORT$"; then
            local next_port=$((APP_PORT + 1))
            while echo "$used_ports" | grep -q "^$next_port$"; do
                next_port=$((next_port + 1))
            done
            APP_PORT="$next_port"
        fi
    fi

    log_info "App port assigned: 127.0.0.1:$APP_PORT (template default: $default_port)"
}

# -----------------------------------------------------------
# 5. Ask for timezone
# -----------------------------------------------------------
ask_timezone() {
    echo ""
    log_info "Available timezones:"
    echo ""
    local -a timezones=(
        "1) Asia/Ho_Chi_Minh (Vietnam, UTC+7)"
        "2) Asia/Bangkok (Thailand, UTC+7)"
        "3) Asia/Singapore (Singapore, UTC+8)"
        "4) Asia/Tokyo (Japan, UTC+9)"
        "5) Asia/Hong_Kong (Hong Kong, UTC+8)"
        "6) America/New_York (US East, UTC-5/-4)"
        "7) America/Los_Angeles (US West, UTC-8/-7)"
        "8) Europe/London (UK, UTC+0/+1)"
        "9) Europe/Berlin (Germany, UTC+1/+2)"
        "10) UTC (UTC+0)"
    )

    for tz in "${timezones[@]}"; do
        echo "  $tz"
    done

    echo ""
    prompt "Choose timezone [1-10]: "
    read -r TZ_CHOICE

    # NOTE: MYSQL_TZ_OFFSET is a fixed offset — MySQL's --default-time-zone
    # does not follow DST transitions. For DST zones (New_York, LA, London,
    # Berlin) the standard-time offset below is wrong half the year. If your
    # data is DST-sensitive, load MySQL's tz tables and use the IANA name, or
    # just keep the database itself on UTC.
    case "$TZ_CHOICE" in
        1)  TZ="Asia/Ho_Chi_Minh"      MYSQL_TZ_OFFSET="+07:00" ;;
        2)  TZ="Asia/Bangkok"          MYSQL_TZ_OFFSET="+07:00" ;;
        3)  TZ="Asia/Singapore"        MYSQL_TZ_OFFSET="+08:00" ;;
        4)  TZ="Asia/Tokyo"            MYSQL_TZ_OFFSET="+09:00" ;;
        5)  TZ="Asia/Hong_Kong"        MYSQL_TZ_OFFSET="+08:00" ;;
        6)  TZ="America/New_York"      MYSQL_TZ_OFFSET="-05:00" ;;
        7)  TZ="America/Los_Angeles"   MYSQL_TZ_OFFSET="-08:00" ;;
        8)  TZ="Europe/London"         MYSQL_TZ_OFFSET="+00:00" ;;
        9)  TZ="Europe/Berlin"         MYSQL_TZ_OFFSET="+01:00" ;;
        10) TZ="UTC"                   MYSQL_TZ_OFFSET="+00:00" ;;
        *)
            log_error "Invalid choice."
            ask_timezone
            return
            ;;
    esac

    log_info "Timezone: $TZ (MySQL offset: $MYSQL_TZ_OFFSET)"
}
create_project() {
    log_section "Creating project: $PROJECT_NAME"

    cp -r "$PROJECTS_DIR/$TEMPLATE" "$PROJECT_DIR"
    log_info "Copied template $TEMPLATE -> $PROJECT_DIR"

    # Replace placeholders in docker-compose.yml
    local compose_file="$PROJECT_DIR/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        sed -i "s|<your-project-name>|$PROJECT_NAME|g" "$compose_file"
        sed -i "s|<your-app-container-name>|${PROJECT_NAME}-app|g" "$compose_file"
        sed -i "s|<your-db-container-name>|${PROJECT_NAME}-db|g" "$compose_file"
        sed -i "s|<your-dockerhub-username>/<your-app-name>|<your-dockerhub-username>/${PROJECT_NAME}|g" "$compose_file"

        # Replace port placeholders with assigned ports
        # For Spring Boot template (MySQL): 8080 -> assigned port
        sed -i "s|127\.0\.0\.1:8080:|127.0.0.1:${APP_PORT}:|g" "$compose_file"
        # For Node.js template (MongoDB): 3000 -> assigned port
        sed -i "s|127\.0\.0\.1:3000:|127.0.0.1:${APP_PORT}:|g" "$compose_file"

        log_info "docker-compose.yml placeholders replaced (ports + project names)."
    fi

    local cd_file="$PROJECT_DIR/cd.yml"
    if [[ -f "$cd_file" ]]; then
        sed -i "s|<your-project-name>|$PROJECT_NAME|g" "$cd_file"
        sed -i "s|<your-app-container-name>|${PROJECT_NAME}-app|g" "$cd_file"
        sed -i "s|<your-dockerhub-username>/<your-app-name>|<your-dockerhub-username>/${PROJECT_NAME}|g" "$cd_file"

        log_info "cd.yml placeholders replaced (project + container names)."
    fi
}

# -----------------------------------------------------------
# 6. Generate nginx.conf with real domain
# -----------------------------------------------------------
generate_nginx_config() {
    log_section "Generating Nginx config for $DOMAIN"

    local nginx_conf="$PROJECT_DIR/nginx.conf"

    cat > "$nginx_conf" <<NGINX
# ==========================================================
# Nginx config for: $PROJECT_NAME
# Domain: $DOMAIN
# Generated by deploy_project.sh
# ==========================================================

# Rate limiting zone
limit_req_zone \$binary_remote_addr zone=${PROJECT_NAME}_limit:10m rate=10r/s;

server {
    server_name $DOMAIN;

    # --- Security Headers ---
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    # --- General ---
    server_tokens off;
    client_max_body_size 10M;

    # --- Block malicious scans (before location / to avoid consuming rate-limit quota) ---
    # Dotfiles/dirs: /.env, /.git/config, /.ssh/id_rsa, ...
    location ~ /\.(env|git|ssh|docker|config) {
        access_log off;
        log_not_found off;
        return 444;
    }
    # Scanner extensions: /index.php, /backup.sql, /db.bak, ... (the old
    # dotfile-only regex missed these — /\.php only matched a literal "/.php")
    location ~* \.(php|sql|bak)$ {
        access_log off;
        log_not_found off;
        return 444;
    }

    location / {
        limit_req zone=${PROJECT_NAME}_limit burst=30 nodelay;

        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    listen 80;
}
NGINX

    log_info "nginx.conf generated: $nginx_conf"
}

# -----------------------------------------------------------
# 7. Link Nginx config + reload
# -----------------------------------------------------------
link_and_reload_nginx() {
    log_section "Linking Nginx config"

    local target="/etc/nginx/sites-available/$PROJECT_NAME"
    local enabled="/etc/nginx/sites-enabled/$PROJECT_NAME"
    local nginx_conf="$PROJECT_DIR/nginx.conf"

    # Symlink to sites-available
    ln -sf "$nginx_conf" "$target"
    log_info "Linked: $nginx_conf -> $target"

    # Enable site
    ln -sf "$target" "$enabled"
    log_info "Enabled: sites-enabled/$PROJECT_NAME"

    # Test and reload
    if nginx -t 2>&1; then
        systemctl reload nginx
        log_info "Nginx reloaded."
    else
        log_error "Nginx config test failed! Fix nginx.conf and retry."
        exit 1
    fi
}

# -----------------------------------------------------------
# 8. Run Certbot for SSL
# -----------------------------------------------------------
setup_ssl() {
    log_section "Setting up SSL for $DOMAIN"

    prompt "Request SSL certificate now? (Y/n): "
    read -r DO_SSL

    if [[ "$DO_SSL" == "n" || "$DO_SSL" == "N" ]]; then
        log_warn "Skipping SSL. Run manually later:"
        log_warn "  sudo certbot --nginx -d $DOMAIN"
        return 0
    fi

    # Ask for an email so Let's Encrypt can warn about expiry / renewal failures.
    # Registering without one (--register-unsafely-without-email) means no such
    # notifications — you only find out a cert lapsed when the site breaks.
    prompt "Email for Let's Encrypt expiry notices (blank = register without email): "
    read -r LE_EMAIL

    local -a certbot_reg_args
    if [[ -n "$LE_EMAIL" ]]; then
        if [[ ! "$LE_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
            log_error "Invalid email: '$LE_EMAIL'"
            exit 1
        fi
        certbot_reg_args=(--email "$LE_EMAIL")
    else
        log_warn "No email given — registering without expiry notifications."
        certbot_reg_args=(--register-unsafely-without-email)
    fi

    log_info "Running Certbot for $DOMAIN ..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos "${certbot_reg_args[@]}" || {
        log_warn "Certbot failed. You can retry manually:"
        log_warn "  sudo certbot --nginx -d $DOMAIN"
        return 0
    }

    log_info "SSL certificate installed for $DOMAIN"
}

# -----------------------------------------------------------
# 9. Create data directories
# -----------------------------------------------------------
prepare_data_dirs() {
    local compose_file="$PROJECT_DIR/docker-compose.yml"
    local data_paths
    # Only match paths before ":" (volume mount left side), skip comments
    data_paths=$(grep -v '^\s*#' "$compose_file" | grep -oP '/opt/data/[^:\s]+' 2>/dev/null | sort -u || true)

    if [[ -n "$data_paths" ]]; then
        while IFS= read -r dir_path; do
            mkdir -p "$dir_path"
            log_info "Created data dir: $dir_path"
        done <<< "$data_paths"
    fi
}

# -----------------------------------------------------------
# 10. Create .env.example with timezone
# -----------------------------------------------------------
create_env_example() {
    local env_file="$PROJECT_DIR/.env.example"

    # Check if template has .env.example
    if [[ ! -f "$env_file" ]]; then
        log_warn "No .env.example found in template. Skipping."
        return 0
    fi

    # Update or add timezone variables
    if grep -q "^TZ=" "$env_file"; then
        # Already has TZ, update the values
        sed -i "s|^TZ=.*|TZ=$TZ|g" "$env_file"
        # Also update MYSQL_TZ_OFFSET if present
        sed -i "s|^MYSQL_TZ_OFFSET=.*|MYSQL_TZ_OFFSET=$MYSQL_TZ_OFFSET|g" "$env_file"
    else
        # Add timezone variables
        cat >> "$env_file" <<EOF

# Timezone configuration (auto-set by deploy_project.sh)
TZ=$TZ
MYSQL_TZ_OFFSET=$MYSQL_TZ_OFFSET
EOF
    fi
    log_info "Timezone set in .env.example: TZ=$TZ"
}

# -----------------------------------------------------------
# 11. Summary
# -----------------------------------------------------------
print_summary() {
    log_section "Deployment Ready!"
    echo ""
    log_info "Project:     $PROJECT_NAME"
    log_info "Domain:      $DOMAIN"
    log_info "Template:    $TEMPLATE"
    log_info "Directory:   $PROJECT_DIR"
    log_info "Nginx:       /etc/nginx/sites-enabled/$PROJECT_NAME"
    log_info "App port:    127.0.0.1:$APP_PORT (loopback)"
    log_info "Timezone:    $TZ (MySQL offset: $MYSQL_TZ_OFFSET)"
    echo ""
    log_info "Next steps:"
    log_info "  1. Edit docker-compose.yml (set your Docker image):"
    log_info "     nano $PROJECT_DIR/docker-compose.yml"
    log_info ""
    log_info "  2. Create .env and fill credentials:"
    log_info "     cp $PROJECT_DIR/.env.example $PROJECT_DIR/.env"
    log_info "     nano $PROJECT_DIR/.env"
    log_info ""
    log_info "  3. Start services for the first time:"
    log_info "     cd $PROJECT_DIR && docker compose up -d"
    echo ""
}

# -----------------------------------------------------------
# MAIN
# -----------------------------------------------------------
main() {
    preflight
    ask_project_name
    ask_domain
    choose_template
    detect_app_port
    ask_timezone
    create_project
    generate_nginx_config
    link_and_reload_nginx
    setup_ssl
    prepare_data_dirs
    create_env_example
    print_summary
}

main "$@"
