# VPS Configuration - Infrastructure as Code

> Automated VPS setup scripts and configuration files for deploying applications on Ubuntu servers.

## Repository Structure

```
vps-config/
├── scripts/
│   ├── setup_vps.sh                  # Main VPS setup script
│   ├── deploy_project.sh             # Interactive project deployment
│   └── backup_db.sh                  # Daily database backup script
├── projects/
│   ├── example-spring-boot/               # Example: Spring Boot + MySQL
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   └── nginx.conf
│   ├── example-node-app/             # Example: Node.js + MongoDB
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   └── nginx.conf
│   └── <your-new-project>/           # Add more projects here
│       ├── ...

├── .gitignore
└── README.md
```

## Prerequisites

- A fresh **Ubuntu 22.04+** VPS (DigitalOcean, AWS, etc.)
- Root or sudo access
- A domain name pointed to your VPS IP (for SSL setup)

## Quick Start - Setup a New VPS from Scratch

### Step 1: Clone this repository

```bash
git clone https://github.com/ariushieu/vps-config.git
cd vps-config
```

### Step 2: Run the setup script

```bash
chmod +x scripts/setup_vps.sh
sudo bash scripts/setup_vps.sh          # default: uses ~/vps-config
# or specify repo path:
sudo bash scripts/setup_vps.sh /opt/vps-config
```

> **⚠️ Reboot after upgrade:** If a kernel, systemd, or netplan update is detected,
> the script will **stop after step 1** and ask you to reboot. After reboot, simply
> re-run the same command — the script is **idempotent** and will skip completed steps.
>
> ```bash
> sudo reboot
> # after reconnecting:
> sudo bash ~/vps-config/scripts/setup_vps.sh
> ```

This script will automatically:

| # | Task | Details |
|---|------|---------|
| 1 | Update system | `apt update && apt upgrade` |
| 2 | Install Docker | Official Docker install script |
| 3 | Install Docker Compose | Via apt package manager |
| 4 | Create Docker network | `backend-network` for inter-container communication |
| 5 | Configure SWAP | 2GB swap file, swappiness = 10 |
| 6 | Setup Firewall (UFW) | Default deny incoming, allow 22, 80, 443 |
| 7 | Install Fail2Ban | SSH brute-force protection (3 retries → ban 1h) |
| 8 | Install Nginx & Certbot | Reverse proxy + automatic SSL |
| 9 | Link Nginx configs | Auto-symlink `nginx.conf` from each project to sites-enabled |
| 10 | Prepare data volumes | Auto-create `/opt/data/<project>/` directories for bind mounts |
| 11 | Setup backup cron | Daily DB backup at 02:00 AM, keep last 7 days |

### Step 3: Deploy a new project (interactive)

```bash
sudo bash scripts/deploy_project.sh
```

The script will ask you:

1. **Project name** — e.g. `mini-social-be`
2. **Domain** — e.g. `api.qhieu.dev` (auto-checks DNS)
3. **Template** — Spring Boot + MySQL or Node.js + MongoDB

Then it automatically:
- Copies template → `projects/mini-social-be/`
- Replaces all placeholders (container names, data paths)
- Generates `nginx.conf` with your real domain + security headers
- Symlinks to Nginx sites-enabled + reloads
- Runs `certbot --nginx -d api.qhieu.dev` for SSL
- Creates `/opt/data/mini-social-be/` directories

After that, just fill `.env` and start:

```bash
cd projects/mini-social-be
cp .env.example .env
nano .env                    # fill real credentials
docker-compose up -d
```

## Common Commands

```bash
# Check running containers
docker ps

# View app logs (from project dir)
cd projects/my-app && docker-compose logs -f

# Restart services
docker-compose down && docker-compose up -d

# Check swap status
free -h

# Check firewall status
sudo ufw status verbose

# Renew SSL certificate
sudo certbot renew --dry-run

# Check data volumes
ls -la /opt/data/

# Manual database backup
sudo bash scripts/backup_db.sh

# Check backup logs
tail -50 /var/log/backup_db.log

# List backups
ls -lh /opt/backups/
```

## Database Backup

The setup script automatically installs a **daily cron job** at 02:00 AM:

```
0 2 * * * bash ~/vps-config/scripts/backup_db.sh >> /var/log/backup_db.log 2>&1
```

**How it works:**
- Scans all project folders (skips `example-*` templates)
- Detects running MySQL/MongoDB containers
- Dumps databases via `mysqldump` / `mongodump`
- Compresses with gzip
- Keeps last **7 days**, auto-deletes older backups

**Backup location:**

```
/opt/backups/
├── my-app/
│   └── mysql/
│       ├── my-app_mysql_2026-04-15_02-00-00.sql.gz
│       └── my-app_mysql_2026-04-14_02-00-00.sql.gz
├── my-api/
│   └── mongo/
│       ├── my-api_mongo_2026-04-15_02-00-00.tar.gz
│       └── my-api_mongo_2026-04-14_02-00-00.tar.gz
```

**Restore example:**

```bash
# MySQL
gunzip -c /opt/backups/my-app/mysql/my-app_mysql_2026-04-15_02-00-00.sql.gz | \
    docker exec -i <mysql-container> mysql -u root -p<password>

# MongoDB
tar -xzf /opt/backups/my-api/mongo/my-api_mongo_2026-04-15_02-00-00.tar.gz -C /tmp
docker cp /tmp/my-api_mongo_2026-04-15_02-00-00 <mongo-container>:/tmp/restore
docker exec <mongo-container> mongorestore /tmp/restore
```

## Adding a New Project

```bash
# Option 1: Interactive (recommended)
sudo bash scripts/deploy_project.sh

# Option 2: Manual
cp -r projects/example-spring-boot projects/my-new-app
nano projects/my-new-app/docker-compose.yml
nano projects/my-new-app/nginx.conf
nano projects/my-new-app/.env.example
sudo bash scripts/setup_vps.sh    # auto-link nginx + create data dirs
cd projects/my-new-app
cp .env.example .env && nano .env
docker-compose up -d
sudo certbot --nginx -d your-domain.com
```

## Data Storage

All persistent data is stored under `/opt/data/<project-name>/`:

```
/opt/data/
├── my-app/
│   └── mysql/          # MySQL data files
├── my-api/
│   └── mongo/          # MongoDB data files
```

This makes backup, migration, and cleanup straightforward.

## Security

This repo follows security best practices:

- **Ports**: App & DB bind to `127.0.0.1` only — not reachable from internet
- **Firewall**: UFW `default deny incoming`, only 22/80/443 open
- **Fail2Ban**: SSH brute-force protection (3 retries → ban 1h)
- **Nginx**: Security headers, rate limiting, `server_tokens off`
- **Docker**: Log rotation (10MB x 3), resource limits (memory/cpu)
- **Secrets**: `.env` files gitignored, never committed
- **SSL**: Auto-renewed via Certbot systemd timer
- **Updates**: `unattended-upgrades` for automatic security patches
- **Backups**: Daily DB dump, integrity verified, 7-day retention

## License

MIT
