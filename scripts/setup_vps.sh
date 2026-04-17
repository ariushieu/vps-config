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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${GREEN}========== $1 ==========${NC}\n"; }
prompt()      { echo -en "${CYAN}[?]${NC} $1"; }

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
# 1a. Find and set fastest Ubuntu mirror
# -----------------------------------------------------------
setup_fastest_mirror() {
    log_info "Finding fastest Ubuntu mirror..."

    # Global mirror list — covers major VPS providers and regions
    local mirrors=(
        # Vietnam (domestic bandwidth >> international)
        "http://opensource.xtdv.net/ubuntu"            # VN - XTDV
        "http://mirror.bizflycloud.vn/ubuntu"          # VN - BizFly

        # VPS provider mirrors (DigitalOcean, Hetzner, OVH, etc.)
        "http://mirrors.digitalocean.com/ubuntu"       # DigitalOcean
        "http://mirror.hetzner.com/ubuntu/packages"    # Hetzner (EU)
        "http://mirror.us.leaseweb.net/ubuntu"         # LeaseWeb (US)

        # Asia-Pacific
        "http://sg.archive.ubuntu.com/ubuntu"          # Singapore
        "http://kr.archive.ubuntu.com/ubuntu"          # Korea
        "http://jp.archive.ubuntu.com/ubuntu"          # Japan
        "http://in.archive.ubuntu.com/ubuntu"          # India

        # US
        "http://us.archive.ubuntu.com/ubuntu"          # US
        "http://archive.ubuntu.com/ubuntu"             # US (default)

        # Europe
        "http://de.archive.ubuntu.com/ubuntu"          # Germany
        "http://gb.archive.ubuntu.com/ubuntu"          # UK
        "http://fr.archive.ubuntu.com/ubuntu"          # France
        "http://nl.archive.ubuntu.com/ubuntu"          # Netherlands
    )

    local fastest_mirror=""
    local fastest_speed=0
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Test all mirrors in parallel (max 3s each)
    for mirror in "${mirrors[@]}"; do
        (
            local speed
            speed=$(curl -o /dev/null -sL --max-time 3 -w "%{speed_download}" "${mirror}/dists/noble/Release" 2>/dev/null || echo "0")
            local speed_kb
            speed_kb=$(awk "BEGIN {printf \"%d\", $speed / 1024}")
            # Write result to temp file (filename = speed for easy sorting)
            echo "${speed} ${speed_kb} ${mirror}" > "$tmp_dir/$(echo "$mirror" | md5sum | cut -d' ' -f1)"
        ) &
    done
    wait

    # Collect results and find fastest
    for result_file in "$tmp_dir"/*; do
        [[ -f "$result_file" ]] || continue
        local speed speed_kb mirror
        read -r speed speed_kb mirror < "$result_file"

        log_info "  $mirror — ${speed_kb} KB/s"

        local speed_int
        speed_int=$(awk "BEGIN {printf \"%d\", $speed}")
        if [[ "$speed_int" -gt "$fastest_speed" ]]; then
            fastest_speed="$speed_int"
            fastest_mirror="$mirror"
        fi
    done
    rm -rf "$tmp_dir"

    local best_kb
    best_kb=$(awk "BEGIN {printf \"%d\", $fastest_speed / 1024}")

    if [[ -n "$fastest_mirror" && "$fastest_speed" -gt 0 ]]; then
        local current_mirror=""
        # Check DEB822 format first (Ubuntu 24.04+), then classic sources.list
        if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
            current_mirror=$(grep -oP 'URIs: \Khttp://[^ ]+' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null | head -1 || true)
        fi
        if [[ -z "$current_mirror" ]]; then
            current_mirror=$(grep -oP 'http://[^ ]+/ubuntu' /etc/apt/sources.list 2>/dev/null | head -1 || true)
        fi
        current_mirror="${current_mirror%/}"
        fastest_mirror="${fastest_mirror%/}"

        if [[ "$current_mirror" == "$fastest_mirror" ]]; then
            log_info "Current mirror is already the fastest: $fastest_mirror (${best_kb} KB/s)"
            return 0
        fi

        # Detect apt source format: DEB822 (noble+) or classic sources.list
        local deb822="/etc/apt/sources.list.d/ubuntu.sources"
        if [[ -f "$deb822" ]]; then
            cp "$deb822" "${deb822}.bak"
            # DEB822 format uses "URIs: http://..."
            sed -i -E "s|URIs: http://[^ ]+/ubuntu/?|URIs: ${fastest_mirror}|g" "$deb822"
            log_info "Updated DEB822 source: $deb822"
        fi

        # Also update classic sources.list if it has real entries
        if [[ -f /etc/apt/sources.list ]] && grep -qE '^deb ' /etc/apt/sources.list 2>/dev/null; then
            cp /etc/apt/sources.list /etc/apt/sources.list.bak
            sed -i -E "s|http://[^ ]+/ubuntu|${fastest_mirror}|g" /etc/apt/sources.list
            log_info "Updated classic source: /etc/apt/sources.list"
        fi

        log_info "Switched to fastest mirror: $fastest_mirror (${best_kb} KB/s)"
    else
        log_warn "Mirror test failed. Keeping current mirror."
    fi
}

# -----------------------------------------------------------
# 1. Update & Upgrade system
# -----------------------------------------------------------
update_system() {
    log_section "Step 1: Updating & Upgrading System"

    # Always find the fastest mirror first
    setup_fastest_mirror

    if ! apt update 2>&1; then
        log_warn "apt update failed. Falling back to archive.ubuntu.com..."
        sed -i -E 's|http://[^ ]+/ubuntu|http://archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list
        apt update
    fi

    log_info "Upgrading packages (this may take a few minutes on first run)..."
    apt upgrade -y

    # Enable automatic security updates
    if ! dpkg -l | grep -q unattended-upgrades; then
        log_info "Installing unattended-upgrades for automatic security patches..."
        apt install unattended-upgrades -y
        dpkg-reconfigure -plow unattended-upgrades
    else
        log_warn "unattended-upgrades already installed."
    fi

    log_info "System updated successfully."

    # Check if reboot is required (kernel/systemd/netplan upgrade)
    if [[ -f /var/run/reboot-required ]]; then
        echo ""
        log_warn "============================================="
        log_warn "  REBOOT REQUIRED after system upgrade!"
        log_warn "  (Kernel, Systemd, or Netplan was updated)"
        log_warn "============================================="
        log_warn ""
        log_warn "Please reboot now, then re-run this script:"
        log_warn "  sudo reboot"
        log_warn "  sudo bash $REPO_DIR/scripts/setup_vps.sh"
        log_warn ""
        log_warn "The script is idempotent — it will skip"
        log_warn "completed steps and continue from step 2."
        echo ""
        exit 0
    fi
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

    # Configure Docker log rotation
    configure_docker_logging
}

# -----------------------------------------------------------
# 2b. Configure Docker log rotation
# -----------------------------------------------------------
configure_docker_logging() {
    local DAEMON_JSON="/etc/docker/daemon.json"

    if [[ -f "$DAEMON_JSON" ]] && grep -q "max-size" "$DAEMON_JSON"; then
        log_warn "Docker log rotation already configured. Skipping."
        return 0
    fi

    log_info "Configuring Docker log rotation..."
    mkdir -p /etc/docker
    cat > "$DAEMON_JSON" <<'DOCKER_CONF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKER_CONF

    systemctl restart docker
    log_info "Docker log rotation set: max 10MB x 3 files per container."
}

# -----------------------------------------------------------
# 3. Install Docker Compose
# -----------------------------------------------------------
install_docker_compose() {
    log_section "Step 3: Installing Docker Compose"

    # Check for V2 plugin first (docker compose), then V1 standalone (docker-compose)
    if docker compose version &>/dev/null; then
        log_warn "Docker Compose V2 already installed: $(docker compose version). Skipping."
        return 0
    fi

    # Remove old V1 if present (buggy with Docker Engine 25+)
    if command -v docker-compose &>/dev/null; then
        log_warn "Removing outdated Docker Compose V1..."
        apt remove docker-compose -y 2>/dev/null || true
    fi

    # Install V2 plugin
    log_info "Installing Docker Compose V2 plugin..."
    apt install docker-compose-v2 -y

    # Create backward-compatible alias so "docker-compose" still works
    if ! command -v docker-compose &>/dev/null; then
        local compose_bin
        compose_bin=$(find /usr/libexec/docker/cli-plugins /usr/lib/docker/cli-plugins /usr/local/lib/docker/cli-plugins -name docker-compose -type f 2>/dev/null | head -1)
        if [[ -n "$compose_bin" ]]; then
            ln -sf "$compose_bin" /usr/local/bin/docker-compose
            log_info "Created alias: docker-compose -> docker compose ($compose_bin)"
        else
            log_warn "Could not find docker-compose plugin binary for alias."
        fi
    fi

    log_info "Docker Compose installed: $(docker compose version)"
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

    # Auto-detect SSH port (some VPS providers use non-standard ports)
    local ssh_port
    ssh_port=$(grep -oP '^\s*Port\s+\K\d+' /etc/ssh/sshd_config 2>/dev/null | head -1 || true)
    # Also check active SSH connection as fallback
    if [[ -z "$ssh_port" || "$ssh_port" == "22" ]]; then
        local active_port
        active_port=$(ss -tlnp | grep sshd | grep -oP ':\K\d+' | head -1 || true)
        if [[ -n "$active_port" ]]; then
            ssh_port="$active_port"
        fi
    fi
    ssh_port="${ssh_port:-22}"

    log_info "Allowing SSH (${ssh_port}/tcp)..."
    ufw allow "$ssh_port/tcp"

    # Also allow 22 if SSH is on a different port (in case they switch back)
    if [[ "$ssh_port" != "22" ]]; then
        log_info "Also allowing default SSH (22/tcp) as fallback..."
        ufw allow 22/tcp
    fi

    log_info "Allowing HTTP (80/tcp)..."
    ufw allow 80/tcp

    log_info "Allowing HTTPS (443/tcp)..."
    ufw allow 443/tcp

    # App ports (8080, 3000, etc.) are bound to 127.0.0.1 only
    # so they don't need UFW rules — Nginx handles external traffic

    # Set default policies
    log_info "Setting default policies: deny incoming, allow outgoing..."
    ufw default deny incoming
    ufw default allow outgoing

    # Enable UFW (non-interactive)
    echo "y" | ufw enable

    ufw status verbose
    log_info "Firewall configured successfully."
}

# -----------------------------------------------------------
# 6b. Install Fail2Ban (brute-force protection)
# -----------------------------------------------------------
install_fail2ban() {
    log_section "Step 6b: Installing Fail2Ban"

    if command -v fail2ban-server &>/dev/null; then
        log_warn "Fail2Ban is already installed. Skipping."
    else
        apt install fail2ban -y
    fi

    # Create local config (won't be overwritten on updates)
    local JAIL_LOCAL="/etc/fail2ban/jail.local"
    if [[ -f "$JAIL_LOCAL" ]]; then
        log_warn "$JAIL_LOCAL already exists. Skipping config."
    else
        cat > "$JAIL_LOCAL" <<'JAIL'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
JAIL
        log_info "Fail2Ban jail.local created (SSH: 3 retries, ban 1h)."
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_info "Fail2Ban installed and running."
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
        data_paths=$(grep -v '^\s*#' "$compose_file" | grep -oP '/opt/data/[^:\s]+' 2>/dev/null | sort -u || true)

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
    (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -
    log_info "Cron job added: daily at 02:00 AM"
    log_info "  $CRON_LINE"
    log_info "Backups stored at: /opt/backups/ (keep last 7 days)"
    log_info "Logs at: /var/log/backup_db.log"
}

# -----------------------------------------------------------
# 11. Configure timezone
# -----------------------------------------------------------
configure_timezone() {
    log_section "Step 11: Configuring Timezone"

    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
    log_info "Current timezone: $current_tz"

    if [[ "$current_tz" != "UTC" && "$current_tz" != "unknown" ]]; then
        log_info "Timezone already configured: $current_tz. Skipping."
        return 0
    fi

    # Show common timezones and let user choose
    echo ""
    log_info "Common timezones:"
    echo "  1) Asia/Ho_Chi_Minh  (UTC+7, Vietnam)"
    echo "  2) Asia/Singapore    (UTC+8)"
    echo "  3) Asia/Tokyo        (UTC+9, Japan)"
    echo "  4) America/New_York  (UTC-5/-4, US East)"
    echo "  5) Europe/London     (UTC+0/+1, UK)"
    echo "  6) UTC               (keep default)"
    echo ""
    prompt "Choose timezone [1-6] (default: 1): "
    read -r TZ_CHOICE

    local tz="Asia/Ho_Chi_Minh"
    case "${TZ_CHOICE:-1}" in
        1) tz="Asia/Ho_Chi_Minh" ;;
        2) tz="Asia/Singapore" ;;
        3) tz="Asia/Tokyo" ;;
        4) tz="America/New_York" ;;
        5) tz="Europe/London" ;;
        6) tz="UTC" ;;
        *) tz="Asia/Ho_Chi_Minh" ;;
    esac

    timedatectl set-timezone "$tz"
    log_info "Timezone set to: $tz"
    log_info "Current time: $(date)"
}

# -----------------------------------------------------------
# 12. Summary
# -----------------------------------------------------------
print_summary() {
    log_section "Setup Complete!"
    echo ""
    log_info "System updated:        OK"
    log_info "Docker:                $(docker --version 2>/dev/null || echo 'N/A')"
    log_info "Docker Compose:        $(docker compose version 2>/dev/null || echo 'N/A')"
    log_info "SWAP:                  $(swapon --show 2>/dev/null | tail -1 || echo 'N/A')"
    log_info "Firewall (UFW):        $(ufw status 2>/dev/null | head -1 || echo 'N/A')"
    log_info "Nginx:                 $(nginx -v 2>&1 || echo 'N/A')"
    log_info "Certbot:               $(certbot --version 2>/dev/null || echo 'N/A')"
    log_info "Timezone:              $(timedatectl show --property=Timezone --value 2>/dev/null || echo 'N/A')"
    log_info "Time:                  $(date)"
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
TOTAL_STEPS=12
CURRENT_STEP=0
SCRIPT_START=$(date +%s)

run_step() {
    local func="$1"
    local desc="$2"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "${CYAN}[$CURRENT_STEP/$TOTAL_STEPS]${NC} $desc"
    local step_start
    step_start=$(date +%s)

    "$func"

    local elapsed=$(( $(date +%s) - step_start ))
    log_info "Done in ${elapsed}s"
}

main() {
    check_root
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  VPS Setup Script — $TOTAL_STEPS steps  ${NC}"
    echo -e "${GREEN}======================================${NC}"

    run_step update_system         "Update & upgrade system"
    run_step install_docker        "Install Docker"
    run_step install_docker_compose "Install Docker Compose"
    run_step create_docker_network "Create Docker network"
    run_step configure_swap        "Configure SWAP (2GB)"
    run_step setup_firewall        "Setup Firewall (UFW)"
    run_step install_fail2ban      "Install Fail2Ban"
    run_step install_nginx_certbot "Install Nginx & Certbot"
    run_step link_nginx_configs    "Link Nginx configs"
    run_step prepare_data_volumes  "Prepare data volumes"
    run_step setup_backup_cron     "Setup backup cron"
    run_step configure_timezone    "Configure timezone"

    local total_elapsed=$(( $(date +%s) - SCRIPT_START ))
    local mins=$(( total_elapsed / 60 ))
    local secs=$(( total_elapsed % 60 ))

    print_summary
    log_info "Total time: ${mins}m ${secs}s"
}

main "$@"
