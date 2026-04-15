# VPS Configuration - Infrastructure as Code

> Automated VPS setup scripts and configuration files for deploying applications on Ubuntu servers.

## Repository Structure

```
vps-config/
├── scripts/
│   └── setup_vps.sh                  # Main VPS setup script
├── projects/
│   ├── mini-social-be/               # Project: Spring Boot + MySQL
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   └── nginx.conf
│   └── <your-new-project>/           # Add more projects here
│       ├── docker-compose.yml
│       ├── .env.example
│       └── nginx.conf
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
sudo bash scripts/setup_vps.sh
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

### Step 3: Deploy a project

```bash
cd projects/mini-social-be/

# 1. Edit docker-compose.yml - replace <...> placeholders with your values
nano docker-compose.yml

# 2. Create .env from template
cp .env.example .env
nano .env

# 3. Start services
docker-compose up -d
```

### Step 4: Configure Nginx + SSL

```bash
# 1. Edit nginx config - replace <your-domain.com> with your actual domain
nano projects/mini-social-be/nginx.conf

# 2. Copy to Nginx
sudo cp projects/mini-social-be/nginx.conf /etc/nginx/sites-available/mini-social-be

# 3. Enable site
sudo ln -s /etc/nginx/sites-available/mini-social-be /etc/nginx/sites-enabled/

# 4. Test and reload
sudo nginx -t && sudo systemctl reload nginx

# 5. Get SSL certificate
sudo certbot --nginx -d your-domain.com
```

## Common Commands

```bash
# Check running containers
docker ps

# View app logs
docker-compose -f projects/mini-social-be/docker-compose.yml logs -f

# Restart services
docker-compose -f projects/mini-social-be/docker-compose.yml down
docker-compose -f projects/mini-social-be/docker-compose.yml up -d

# Check swap status
free -h

# Check firewall status
sudo ufw status verbose

# Renew SSL certificate
sudo certbot renew --dry-run
```

## Adding a New Project

```bash
# 1. Create project directory
mkdir projects/my-new-app

# 2. Copy template from existing project
cp projects/mini-social-be/docker-compose.yml projects/my-new-app/
cp projects/mini-social-be/.env.example       projects/my-new-app/
cp projects/mini-social-be/nginx.conf         projects/my-new-app/

# 3. Edit all 3 files with your new project's config
nano projects/my-new-app/docker-compose.yml
nano projects/my-new-app/.env.example
nano projects/my-new-app/nginx.conf

# 4. Deploy
cd projects/my-new-app && docker-compose up -d
```

## Security Notes

- Never commit `.env` files containing secrets
- Always use strong passwords for MySQL
- Keep your system updated: `sudo apt update && sudo apt upgrade -y`
- SSL certificates auto-renew via Certbot's systemd timer

## License

MIT
