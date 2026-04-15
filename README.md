# VPS Configuration - Infrastructure as Code

> Automated VPS setup scripts and configuration files for deploying applications on Ubuntu servers.

## Repository Structure

```
vps-config/
├── scripts/
│   ├── setup_vps.sh                  # Main VPS setup script
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

This script will automatically:

| # | Task | Details |
|---|------|---------|
| 1 | Update system | `apt update && apt upgrade` |
| 2 | Install Docker | Official Docker install script |
| 3 | Install Docker Compose | Via apt package manager |
| 4 | Create Docker network | `backend-network` for inter-container communication |
| 5 | Configure SWAP | 2GB swap file, swappiness = 10 |
| 6 | Setup Firewall (UFW) | Allow ports: 22, 80, 443, 8080 |
| 7 | Install Nginx & Certbot | Reverse proxy + automatic SSL |
| 8 | Link Nginx configs | Auto-symlink `nginx.conf` from each project to sites-enabled |
| 9 | Prepare data volumes | Auto-create `/opt/data/<project>/` directories for bind mounts |
| 10 | Setup backup cron | Daily DB backup at 02:00 AM, keep last 7 days |

### Step 3: Add a new project & deploy

```bash
# 1. Copy a template
cp -r projects/example-spring-boot projects/my-app    # Spring Boot + MySQL
cp -r projects/example-node-app    projects/my-app    # Node.js + MongoDB

# 2. Edit all 3 files
nano projects/my-app/docker-compose.yml    # replace <...> placeholders
nano projects/my-app/nginx.conf            # replace <your-domain.com>
cp projects/my-app/.env.example projects/my-app/.env
nano projects/my-app/.env                  # fill real credentials

# 3. Re-run script to auto-link nginx + create data dirs
sudo bash scripts/setup_vps.sh

# 4. Start services
cd projects/my-app && docker-compose up -d

# 5. Get SSL
sudo certbot --nginx -d your-domain.com
```

> **Note:** `example-*` folders are skipped automatically by the script.
> Only real project folders get nginx-linked and data dirs created.

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
# 1. Copy the template that matches your stack
cp -r projects/example-spring-boot projects/my-new-app   # Spring Boot + MySQL
cp -r projects/example-node-app    projects/my-new-app   # Node.js + MongoDB

# 2. Edit all 3 files with your new project's config
nano projects/my-new-app/docker-compose.yml
nano projects/my-new-app/.env.example
nano projects/my-new-app/nginx.conf

# 3. Run script to auto-link nginx + create /opt/data/ dirs
sudo bash scripts/setup_vps.sh

# 4. Deploy
cd projects/my-new-app
cp .env.example .env && nano .env
docker-compose up -d
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

## Security Notes

- Never commit `.env` files containing secrets
- Always use strong passwords for MySQL
- Keep your system updated: `sudo apt update && sudo apt upgrade -y`
- SSL certificates auto-renew via Certbot's systemd timer

## License

MIT
