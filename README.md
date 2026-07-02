# VPS Configuration - Infrastructure as Code

> Automated VPS setup scripts and configuration files for deploying applications on Ubuntu servers.

## Repository Structure

```
vps-setup-kit/
├── scripts/
│   ├── setup_vps.sh                  # Main VPS setup script
│   ├── deploy_project.sh             # Interactive project deployment
│   └── backup_db.sh                  # Daily database backup script
├── projects/
│   ├── example-spring-boot/          # Example: Spring Boot + MySQL
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   ├── nginx.conf
│   │   ├── ci.yml                    # GitHub Actions CI template
│   │   └── cd.yml                    # GitHub Actions CD template
│   ├── example-node-app/             # Example: Node.js + MongoDB
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   ├── nginx.conf
│   │   ├── ci.yml                    # GitHub Actions CI template
│   │   └── cd.yml                    # GitHub Actions CD template
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
git clone https://github.com/ariushieu/vps-setup-kit.git
cd vps-setup-kit
```

### Step 2: Run the setup script

```bash
chmod +x scripts/setup_vps.sh
sudo bash scripts/setup_vps.sh          # default: uses ~/vps-setup-kit
# or specify repo path:
sudo bash scripts/setup_vps.sh /opt/vps-setup-kit
```

> **⚠️ Reboot after upgrade:** If a kernel, systemd, or netplan update is detected,
> the script will **stop after step 1** and ask you to reboot. After reboot, simply
> re-run the same command — the script is **idempotent** and will skip completed steps.
>
> ```bash
> sudo reboot
> # after reconnecting:
> sudo bash ~/vps-setup-kit/scripts/setup_vps.sh
> ```

This script will automatically:

| # | Task | Details |
|---|------|---------|
| 1 | Update system | `apt update && apt upgrade` |
| 2 | Install Docker | Official Docker install script |
| 3 | Install Docker Compose | Docker Compose **V2** plugin (`docker compose`) with `docker-compose` symlink for back-compat |
| 4 | Configure SWAP | 2GB swap file, swappiness = 10 |
| 5 | Setup Firewall (UFW) | Default deny incoming, allow 22, 80, 443 |
| 6 | Install Fail2Ban | SSH brute-force protection (3 retries → ban 1h) |
| 7 | Install Nginx & Certbot | Reverse proxy + automatic SSL |
| 8 | Link Nginx configs | Auto-symlink `nginx.conf` from each project to sites-enabled |
| 9 | Prepare data volumes | Auto-create `/opt/data/<project>/` directories for bind mounts |
| 10 | Setup backup cron | Daily DB backup at 02:00 AM, keep last 7 days |
| 11 | Configure timezone | Interactive timezone selection (VN, SG, JP, US, UK, UTC, or keep current) |

> Each project gets its **own private Compose network** (`<project>_default`). The kit deliberately
> does not create a single shared Docker network — sharing one would make the `mysql`/`mongo`
> service alias resolve to every project's database, so an app could connect to the wrong DB.

> **⚠️ Non-standard SSH port:** Some VPS providers use custom SSH ports (e.g. 8686 instead of 22).
> The script **auto-detects your SSH port** and opens it in UFW, so you won't get locked out.

> **⚠️ Container timezone:** Host timezone does **NOT** propagate into Docker containers.
> After Step 11, the script prints the two lines you need to add to each project's `.env`:
>
> ```
> TZ=Asia/Ho_Chi_Minh
> MYSQL_TZ_OFFSET=+07:00     # only if you use MySQL
> ```
>
> Templates already reference `${TZ}` / `${MYSQL_TZ_OFFSET}` in `docker-compose.yml`, so just
> fill `.env` and run `docker compose up -d` for the first start. See [Timezone handling](#timezone-handling) below.

### Step 3: Deploy a new project (interactive)

> **Before you start:** Point your domain's DNS (A record) to this VPS's IP address.
> Certbot needs DNS to be active to issue SSL certificates.
>
> ```
> Type: A
> Name: api.qhieu.dev (or your domain)
> Value: <your-vps-ip>
> TTL: Auto
> ```
>
> Verify with: `dig +short api.qhieu.dev` — should return your VPS IP.

```bash
sudo bash scripts/deploy_project.sh
```

The script will ask you:

1. **Project name** — e.g. `mini-social-be`
2. **Domain** — e.g. `api.qhieu.dev` (auto-checks DNS)
3. **Template** — Spring Boot + MySQL or Node.js + MongoDB
4. **Timezone** — Select from 10 common timezones (VN, TH, SG, JP, HK, US, EU, UTC)

Then it automatically:
- Copies template → `projects/mini-social-be/`
- **Auto-assigns unique port** (8080 → 8081 → 8082... if already taken)
- Replaces all placeholders (container names, data paths, app port)
- Generates `nginx.conf` with your real domain + security headers
- Symlinks to Nginx sites-enabled + reloads
- Runs `certbot --nginx -d api.qhieu.dev` for SSL
- Creates `/opt/data/mini-social-be/` directories
- Pre-fills `.env.example` with your selected timezone

After that, just fill `.env` and start:

```bash
cd projects/mini-social-be
cp .env.example .env
nano .env                    # fill real credentials
docker compose up -d
```

> **MySQL credentials:** `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, and `MYSQL_PASSWORD` initialize the MySQL data directory only on the first start. If `/opt/data/<project>/mysql` already exists, changing `.env` does not change database passwords; update users inside MySQL or intentionally recreate/restore the data directory.

## Common Commands

```bash
# Check running containers
docker ps

# View app logs (from project dir)
cd projects/my-app && docker-compose logs -f

# Redeploy app without touching database
docker compose pull app && docker compose up -d --no-deps --force-recreate app

# Full stack restart only when you intentionally want to restart DB too
docker compose up -d

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
sudo tail -50 /var/log/backup_db.log

# List backups
ls -lh /opt/backups/
```

## Database Backup

The setup script automatically installs a **daily cron job** at 02:00 AM:

```
0 2 * * * /bin/bash '/root/vps-setup-kit/scripts/backup_db.sh' '/root/vps-setup-kit' >> '/var/log/backup_db.log' 2>&1
```

**How it works:**
- Scans all project folders (skips `example-*` templates)
- Detects running MySQL/MongoDB containers
- Dumps the MySQL schema named by `MYSQL_DATABASE` via `mysqldump`
- Dumps the MongoDB database named by `MONGO_INITDB_DATABASE` via `mongodump`
- Compresses with gzip
- Uses a lock file to avoid overlapping cron/manual backup runs
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
# MySQL - use the guarded restore helper.
# It rejects dumps that contain mysql system schema, user, or privilege statements.
# Prompts for 'yes' before overwriting; pass --yes for scripted use.
sudo bash scripts/restore_mysql.sh \
    /opt/backups/my-app/mysql/my-app_mysql_2026-04-15_02-00-00.sql.gz \
    <mysql-container>

# MongoDB - use the guarded restore helper.
# It rejects dumps that contain admin, config, or local system databases.
# Prompts for 'yes' before running mongorestore --drop on the target.
sudo bash scripts/restore_mongo.sh \
    /opt/backups/my-api/mongo/my-api_mongo_2026-04-15_02-00-00.tar.gz \
    <mongo-container>
```

**Restore flags:**
- `--yes` / `-y` — skip the interactive confirmation (e.g. inside automation).
- `--force` — bypass the forbidden-pattern scan. Only use when you trust the dump and the scan is producing a false positive (e.g. application data containing SQL-like text).

**Database backup/restore safety:**
- MySQL backups are scoped to the single schema in `MYSQL_DATABASE`; the script refuses empty values, system schemas, and unsafe database names.
- Backups are deleted if the generated SQL contains `mysql`, `information_schema`, `performance_schema`, `sys`, `CREATE USER`, `GRANT`, or similar global privilege statements.
- Do not restore legacy dumps made with `mysqldump --all-databases` into a new container. Those dumps can overwrite `mysql.user`, replace Docker-created passwords, break the app login, and lock you out of MySQL.
- MongoDB backups are scoped to `MONGO_INITDB_DATABASE`; the script refuses empty values and system databases (`admin`, `config`, `local`).
- Do not restore legacy all-database MongoDB dumps into a new container. They can restore system database metadata from the old host.

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
docker compose up -d
sudo certbot --nginx -d your-domain.com
```

## CI/CD with GitHub Actions

Each project template includes **CI/CD workflow files** (`ci.yml` + `cd.yml`). These are templates — copy them to your **project source code repo** (not this vps-setup-kit repo).

### Setup

```bash
# In your project source code repo:
mkdir -p .github/workflows

# If you used deploy_project.sh, copy from the generated project folder:
cp ~/vps-setup-kit/projects/mini-social-be/ci.yml .github/workflows/ci.yml
cp ~/vps-setup-kit/projects/mini-social-be/cd.yml .github/workflows/cd.yml

# If you are setting up manually, copy from the stack template instead:
cp ~/vps-setup-kit/projects/example-spring-boot/ci.yml .github/workflows/ci.yml
cp ~/vps-setup-kit/projects/example-spring-boot/cd.yml .github/workflows/cd.yml
# or for Node.js:
cp ~/vps-setup-kit/projects/example-node-app/ci.yml .github/workflows/ci.yml
cp ~/vps-setup-kit/projects/example-node-app/cd.yml .github/workflows/cd.yml
```

### Replace placeholders

Open each file and replace any remaining `<...>` values:

| Placeholder | Example |
|-------------|---------|
| `<your-dockerhub-username>` | `ariushieu` |
| `<your-app-name>` | `mini-social-be` |
| `<your-project-name>` | `mini-social-be` |
| `<your-app-container-name>` | `mini-social-be-app` |

### Add GitHub Secrets

Go to your repo → **Settings → Secrets and variables → Actions**, add:

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub **Access Token** (not password!) |
| `VPS_HOST` | VPS IP address or hostname |
| `VPS_USERNAME` | SSH user (e.g. `root`) |
| `VPS_SSH_KEY` | Private SSH key for VPS access |

> **Security note:** Always use a Docker Hub **Access Token** instead of your password.
> Create one at: https://hub.docker.com/settings/security

### How it works

```
Push to feature branch → CI: build + test
Push/merge to main     → CD: build → push to DockerHub → deploy to VPS
```

- **CI** (`ci.yml`): Runs on all branches except `main`. Builds and tests only.
- **CD** (`cd.yml`): Runs on `main` only. Builds Docker image, pushes to DockerHub with `latest` + git SHA tags, SSHs into VPS to pull and restart, then verifies health.

### Your project repo structure

```
my-project/                    ← your source code repo on GitHub
├── .github/workflows/
│   ├── ci.yml                 ← copied from vps-setup-kit template
│   └── cd.yml                 ← copied from vps-setup-kit template
├── Dockerfile
├── src/
└── ...
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

## Accessing the database

The database containers **do not publish a host port** — nothing listens on
`127.0.0.1:3306` / `:27017` on the VPS. This removes a needless attack surface and
avoids port collisions between projects. The app talks to the DB over the project's
private Compose network using the service alias (`mysql` / `mongo`).

When you need a shell or a GUI against the DB:

```bash
# MySQL shell inside the container
docker exec -it <project>-db mysql -u root -p

# MongoDB shell inside the container
docker exec -it <project>-db mongosh -u "$MONGO_USERNAME" -p

# GUI tool (DBeaver, Compass, TablePlus) from your laptop — tunnel over SSH.
# This forwards local 3307 -> the DB *inside* the container via the VPS.
# Because there is no published port, point the tunnel at the container IP,
# or temporarily publish the port for a one-off session:
ssh -L 3307:127.0.0.1:3306 user@your-vps      # only works if you publish the port
```

If you genuinely need the port published for a debugging session, add a temporary
`ports: ["127.0.0.1:3306:3306"]` back to that one project's `docker-compose.yml`,
`docker compose up -d`, and remove it when done. Keep it **loopback-only** (`127.0.0.1:`)
and never `0.0.0.0`.

## Timezone handling

Host and container timezones are **independent**. Setting `timedatectl set-timezone` on the host
does not affect Docker containers — JVM, Node `Date()`, MySQL `NOW()`, etc. all keep using the
container's clock (default UTC).

This repo's templates solve it with two `.env` variables:

| Variable | Used by | Example (Vietnam) |
|----------|---------|-------------------|
| `TZ` | App + DB containers (system clock, JVM, Node, logs) | `Asia/Ho_Chi_Minh` |
| `MYSQL_TZ_OFFSET` | MySQL `--default-time-zone` flag | `+07:00` |

`docker-compose.yml` already references both:

```yaml
services:
  app:
    environment:
      TZ: ${TZ:-UTC}
  mysql:
    environment:
      TZ: ${TZ:-UTC}
    command: --default-time-zone=${MYSQL_TZ_OFFSET:-+00:00}
```

**Why MySQL needs a separate variable:**
- MySQL `TIMESTAMP` columns convert UTC ↔ session timezone on read/write
- Without `--default-time-zone`, MySQL falls back to `SYSTEM` (the container's clock) — works,
  but breaks if you restore a dump on a host with a different tz
- Pinning explicit `+07:00` makes behavior deterministic across hosts
- `DATETIME` columns store literal values (no conversion) and are always safe
- MongoDB always stores dates in UTC; `TZ` only affects container logs

**To change timezone for an existing project:**

```bash
cd ~/vps-setup-kit/projects/my-app
nano .env                    # update TZ for app-only changes
docker compose up -d --no-deps --force-recreate app

# If you change MYSQL_TZ_OFFSET, schedule DB downtime and restart the stack:
# docker compose up -d
```

## Security

This repo follows security best practices:

- **Ports**: The app binds to `127.0.0.1:<port>` (Nginx proxies to it); the **database publishes no host port at all** — it is reachable only over the project's private Compose network. Neither is reachable from the internet.
- **Network isolation**: Each project runs on its own `<project>_default` network, so one project's app can't reach another project's database.
- **Firewall**: UFW `default deny incoming`, only 22/80/443 open
- **Fail2Ban**: SSH brute-force protection (3 retries → ban 1h) + Nginx rate-limit jail (5 violations in 10m → ban 1h via UFW)
- **Nginx**: Security headers, rate limiting (`burst=30 nodelay`), `server_tokens off`, malicious scan blocker (`.env`, `.git`, `.ssh`, `.php`, `.sql`, `.bak` → instant `444` drop)
- **Docker**: Log rotation (10MB x 3), resource limits (memory/cpu)
- **Secrets**: `.env` files gitignored, never committed
- **SSL**: Auto-renewed via Certbot systemd timer
- **Updates**: `unattended-upgrades` for automatic security patches
- **Backups**: Daily DB dump, integrity verified, 7-day retention
- **Deployment**: CD recreates only the `app` service with `--no-deps`, so routine deploys do not restart the database

> **Note on `dhcpcd` user in `ps aux`:** If you see processes owned by the `dhcpcd` user, this is
> expected behavior caused by Linux host UID mapping. Docker container users (e.g. UID 101 for nginx)
> map to host usernames by `/etc/passwd` lookup — UID 101 happens to be `dhcpcd` on many systems.
> These are your normal containerized processes, not a separate service.

## License

MIT
