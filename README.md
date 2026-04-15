# VPS Configuration - Infrastructure as Code

> Automated VPS setup scripts and configuration files for deploying applications on Ubuntu servers.

## Repository Structure

```
vps-config/
├── scripts/
│   └── setup_vps.sh              # Main VPS setup script (Docker, SWAP, UFW, Nginx)
├── nginx/
│   └── sites-available/
│       └── mini-social-be         # Nginx reverse proxy config (example template)
├── docker/
│   └── mini-social-be/
│       ├── docker-compose.yml     # Docker Compose for Spring Boot + MySQL
│       └── .env.example           # Environment variables template
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

### Step 3: Configure Nginx for your project

```bash
# Edit the template - replace <your-domain.com> with your actual domain
nano nginx/sites-available/mini-social-be

# Copy the Nginx config
sudo cp nginx/sites-available/mini-social-be /etc/nginx/sites-available/

# Create symlink to enable the site
sudo ln -s /etc/nginx/sites-available/mini-social-be /etc/nginx/sites-enabled/

# Test and reload
sudo nginx -t
sudo systemctl reload nginx
```

### Step 4: Get SSL certificate

```bash
sudo certbot --nginx -d your-domain.com
```

### Step 5: Deploy your application

```bash
# Navigate to your project's docker directory
cd docker/mini-social-be/

# Edit docker-compose.yml - replace <...> placeholders with your values
nano docker-compose.yml

# Create .env file from template
cp .env.example .env
nano .env  # Fill in your actual values

# Start the services
docker-compose up -d

# Check logs
docker-compose logs -f
```

## Project Configurations

### mini-social-be (Spring Boot + MySQL)

- **App container**: `<your-app-container-name>` on port `8080`
- **MySQL container**: `<your-db-container-name>` on port `3306`
- **Network**: `backend-network`
- **Nginx**: Reverse proxy from `your-domain.com` to `localhost:8080` with SSL

## Common Commands

```bash
# Check running containers
docker ps

# View app logs
docker logs -f <your-app-container-name>

# Restart services
docker-compose down && docker-compose up -d

# Check swap status
free -h

# Check firewall status
sudo ufw status verbose

# Renew SSL certificate
sudo certbot renew --dry-run
```

## Security Notes

- Never commit `.env` files containing secrets
- Always use strong passwords for MySQL
- Keep your system updated: `sudo apt update && sudo apt upgrade -y`
- SSL certificates auto-renew via Certbot's systemd timer

## Adding a New Project

1. Create a new directory under `docker/`:
   ```bash
   mkdir docker/my-new-project
   ```
2. Add a `docker-compose.yml` and `.env.example`
3. Add Nginx config under `nginx/sites-available/`
4. Update this README

## License

MIT
