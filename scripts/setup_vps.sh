#!/bin/bash
# ============================================================
# setup_vps.sh - Automated VPS Setup Script
# Description: Setup Ubuntu VPS with Docker, SWAP, Firewall,
#              Nginx and Certbot
# Author: ariushieu
#
# Usage: sudo bash setup_vps.sh [REPO_DIR]
#   REPO_DIR: path to vps-config repo (default: ~/vps-config)
# ============================================================

set -euo pipefail

REPO_DIR="${1:-$HOME/vps-config}"

# -----------------------------------------------------------
# Color & Log helpers
# -----------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${GREEN}========== $1 ==========${NC}\n"; }

# -----------------------------------------------------------
# 0. Check root privileges
# -----------------------------------------------------------
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root. Use: sudo bash setup_vps.sh"
        exit 1
    fi
    log_info "Running as root - OK"
}

# -----------------------------------------------------------
# 1. Update & Upgrade system
# -----------------------------------------------------------
update_system() {
    log_section "Step 1: Updating & Upgrading System"
    apt update && apt upgrade -y
    log_info "System updated successfully."
}

# -----------------------------------------------------------
# 2. Install Docker
# -----------------------------------------------------------
install_docker() {
    log_section "Step 2: Installing Docker"

    if command -v docker &>/dev/null; then
        log_warn "Docker is already installed: $(docker --version). Skipping."
        return 0
    fi

    log_info "Downloading Docker install script..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm -f get-docker.sh

    log_info "Docker installed: $(docker --version)"
}

# -----------------------------------------------------------
# 3. Install Docker Compose
# -----------------------------------------------------------
install_docker_compose() {
    log_section "Step 3: Installing Docker Compose"

    if command -v docker-compose &>/dev/null; then
        log_warn "Docker Compose is already installed: $(docker-compose --version). Skipping."
        return 0
    fi

    apt install docker-compose -y
    log_info "Docker Compose installed: $(docker-compose --version)"
}

# -----------------------------------------------------------
# 4. Create Docker network
# -----------------------------------------------------------
create_docker_network() {
    log_section "Step 4: Creating Docker Network"

    if docker network ls | grep -q "backend-network"; then
        log_warn "Docker network 'backend-network' already exists. Skipping."
        return 0
    fi

    docker network create backend-network
    log_info "Docker network 'backend-network' created."
}

# -----------------------------------------------------------
# 5. Configure SWAP (2GB, swappiness=10)
# -----------------------------------------------------------
configure_swap() {
    log_section "Step 5: Configuring SWAP (2GB)"

    local SWAPFILE="/swapfile"
    local SWAP_SIZE="2G"
    local SWAPPINESS=10

    # Check if swap file already exists
    if [[ -f "$SWAPFILE" ]]; then
        log_warn "Swap file $SWAPFILE already exists. Skipping swap creation."
    else
        log_info "Creating ${SWAP_SIZE} swap file..."
        fallocate -l "$SWAP_SIZE" "$SWAPFILE"
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"
        swapon "$SWAPFILE"
        log_info "Swap file created and activated."

        # Persist in /etc/fstab
        if ! grep -q "$SWAPFILE" /etc/fstab; then
            cp /etc/fstab /etc/fstab.bak
            echo "$SWAPFILE none swap sw 0 0" | tee -a /etc/fstab
            log_info "Swap entry added to /etc/fstab."
        else
            log_warn "Swap entry already exists in /etc/fstab. Skipping."
        fi
    fi

    # Set swappiness
    sysctl vm.swappiness="$SWAPPINESS"
    log_info "vm.swappiness set to $SWAPPINESS (runtime)."

    # Persist swappiness in /etc/sysctl.conf (safe - no duplicate)
    if grep -q "^vm.swappiness" /etc/sysctl.conf; then
        log_warn "vm.swappiness already configured in /etc/sysctl.conf. Skipping."
    else
        echo "vm.swappiness=$SWAPPINESS" | tee -a /etc/sysctl.conf
        log_info "vm.swappiness=$SWAPPINESS written to /etc/sysctl.conf."
    fi

    free -h
    log_info "SWAP configuration completed."
}

# -----------------------------------------------------------
# 6. Setup Firewall (UFW)
# -----------------------------------------------------------
setup_firewall() {
    log_section "Step 6: Setting up Firewall (UFW)"

    # Install UFW if not present
    if ! command -v ufw &>/dev/null; then
        apt install ufw -y
    fi

    log_info "Allowing SSH (22/tcp)..."
    ufw allow 22/tcp

    log_info "Allowing HTTP (80/tcp)..."
    ufw allow 80/tcp

    log_info "Allowing HTTPS (443/tcp)..."
    ufw allow 443/tcp

    log_info "Allowing App port (8080/tcp)..."
    ufw allow 8080/tcp

    # Enable UFW (non-interactive)
    echo "y" | ufw enable

    ufw status verbose
    log_info "Firewall configured successfully."
}

# -----------------------------------------------------------
# 7. Install Nginx & Certbot
# -----------------------------------------------------------
install_nginx_certbot() {
    log_section "Step 7: Installing Nginx & Certbot"

    if command -v nginx &>/dev/null; then
        log_warn "Nginx is already installed: $(nginx -v 2>&1). Skipping install."
    else
        log_info "Installing Nginx..."
        apt install nginx -y
    fi

    log_info "Installing Certbot & Nginx plugin..."
    apt install certbot python3-certbot-nginx -y

    # Remove default site if exists
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        rm /etc/nginx/sites-enabled/default
        log_info "Removed default Nginx site."
    fi

    systemctl enable nginx
    systemctl restart nginx

    log_info "Nginx & Certbot installed successfully."
}

# -----------------------------------------------------------
# 8. Auto-link Nginx configs from projects/
# -----------------------------------------------------------
link_nginx_configs() {
    log_section "Step 8: Linking Nginx Configs"

    local PROJECTS_DIR="$REPO_DIR/projects"

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        log_warn "Projects directory not found: $PROJECTS_DIR. Skipping."
        return 0
    fi

    for project_dir in "$PROJECTS_DIR"/*/; do
        local project_name
        project_name=$(basename "$project_dir")
        local nginx_conf="$project_dir/nginx.conf"

        # Skip example- prefixed folders (they are templates)
        if [[ "$project_name" == example-* ]]; then
            log_warn "Skipping template: $project_name"
            continue
        fi

        if [[ ! -f "$nginx_conf" ]]; then
            log_warn "No nginx.conf in $project_name. Skipping."
            continue
        fi

        local target="/etc/nginx/sites-available/$project_name"
        local enabled="/etc/nginx/sites-enabled/$project_name"

        # Symlink to sites-available
        if [[ -L "$target" || -f "$target" ]]; then
            log_warn "sites-available/$project_name already exists. Removing old..."
            rm -f "$target"
        fi
        ln -s "$nginx_conf" "$target"
        log_info "Linked: $nginx_conf -> $target"

        # Enable site (symlink to sites-enabled)
        if [[ -L "$enabled" ]]; then
            rm -f "$enabled"
        fi
        ln -s "$target" "$enabled"
        log_info "Enabled: sites-enabled/$project_name"
    done

    # Test and reload
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log_info "Nginx reloaded successfully."
    else
        log_error "Nginx config test failed! Check your nginx.conf files."
        nginx -t
    fi
}

# -----------------------------------------------------------
# 9. Prepare data volume directories for Docker bind mounts
# -----------------------------------------------------------
prepare_data_volumes() {
    log_section "Step 9: Preparing Data Volume Directories"

    local PROJECTS_DIR="$REPO_DIR/projects"
    local DATA_ROOT="/opt/data"

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        log_warn "Projects directory not found: $PROJECTS_DIR. Skipping."
        return 0
    fi

    for project_dir in "$PROJECTS_DIR"/*/; do
        local project_name
        project_name=$(basename "$project_dir")
        local compose_file="$project_dir/docker-compose.yml"

        # Skip example- prefixed folders
        if [[ "$project_name" == example-* ]]; then
            continue
        fi

        if [[ ! -f "$compose_file" ]]; then
            continue
        fi

        # Extract /opt/data/... paths from docker-compose.yml
        local data_paths
        data_paths=$(grep -oP '/opt/data/[^\s:]+' "$compose_file" 2>/dev/null | sort -u || true)

        if [[ -z "$data_paths" ]]; then
            log_warn "No /opt/data/ volumes in $project_name. Skipping."
            continue
        fi

        while IFS= read -r dir_path; do
            if [[ -d "$dir_path" ]]; then
                log_warn "Directory already exists: $dir_path"
            else
                mkdir -p "$dir_path"
                log_info "Created: $dir_path"
            fi
        done <<< "$data_paths"
    done

    log_info "Data volume directories ready."
}

# -----------------------------------------------------------
# 10. Setup daily database backup cron job
# -----------------------------------------------------------
setup_backup_cron() {
    log_section "Step 10: Setting up Daily Database Backup"

    local BACKUP_SCRIPT="$REPO_DIR/scripts/backup_db.sh"
    local CRON_LINE="0 2 * * * bash $BACKUP_SCRIPT $REPO_DIR >> /var/log/backup_db.log 2>&1"

    if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        log_warn "Backup script not found: $BACKUP_SCRIPT. Skipping."
        return 0
    fi

    chmod +x "$BACKUP_SCRIPT"

    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -qF "backup_db.sh"; then
        log_warn "Backup cron job already exists. Skipping."
        crontab -l 2>/dev/null | grep "backup_db.sh"
        return 0
    fi

    # Add cron job
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    log_info "Cron job added: daily at 02:00 AM"
    log_info "  $CRON_LINE"
    log_info "Backups stored at: /opt/backups/ (keep last 7 days)"
    log_info "Logs at: /var/log/backup_db.log"
}

# -----------------------------------------------------------
# 11. Summary
# -----------------------------------------------------------
print_summary() {
    log_section "Setup Complete!"
    echo ""
    log_info "System updated:        OK"
    log_info "Docker:                $(docker --version 2>/dev/null || echo 'N/A')"
    log_info "Docker Compose:        $(docker-compose --version 2>/dev/null || echo 'N/A')"
    log_info "SWAP:                  $(swapon --show 2>/dev/null | tail -1 || echo 'N/A')"
    log_info "Firewall (UFW):        $(ufw status 2>/dev/null | head -1 || echo 'N/A')"
    log_info "Nginx:                 $(nginx -v 2>&1 || echo 'N/A')"
    log_info "Certbot:               $(certbot --version 2>/dev/null || echo 'N/A')"
    echo ""
    log_info "Next steps:"
    log_info "  1. Copy an example template:  cp -r projects/example-spring-boot projects/my-app"
    log_info "  2. Edit docker-compose.yml, .env.example, nginx.conf"
    log_info "  3. Re-run script to auto-link:  sudo bash setup_vps.sh"
    log_info "  4. Get SSL cert:    certbot --nginx -d your-domain.com"
    log_info "  5. Deploy with:     cd projects/my-app && docker-compose up -d"
    log_info "  6. Manual backup:   sudo bash scripts/backup_db.sh"
    echo ""
}

# -----------------------------------------------------------
# MAIN
# -----------------------------------------------------------
main() {
    check_root
    update_system
    install_docker
    install_docker_compose
    create_docker_network
    configure_swap
    setup_firewall
    install_nginx_certbot
    link_nginx_configs
    prepare_data_volumes
    setup_backup_cron
    print_summary
}

main "$@"
