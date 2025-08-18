#!/bin/bash

# Automated Debian 12 Server Setup
# Caddy + Grav CMS + Hugo + PHP Form Handler
# For Alpha Omega Strategies
# 
# Usage: ./server-setup.sh
# Run from the cloned GitHub repo directory

set -e  # Exit on any error

echo "========================================="
echo "Alpha Omega Strategies Server Setup"
echo "Debian 12 + Caddy + Grav + Hugo Stack"
echo "========================================="

# Get the script directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Running from: $SCRIPT_DIR"

# Phase 1: System Updates and Basic Packages
echo ""
echo "Phase 1: System Updates and Basic Packages"
echo "-------------------------------------------"
apt update && apt upgrade -y

# Set timezone
timedatectl set-timezone America/Chicago
echo "SUCCESS: Timezone set to America/Chicago"

# Create swap file (8GB for 4GB RAM system)
echo "Creating 8GB swap file..."
if [ ! -f /swapfile ]; then
    fallocate -l 8G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "SUCCESS: Swap file created and activated"
else
    echo "SUCCESS: Swap file already exists"
fi

# Install essential packages (including UFW)
echo "Installing essential packages..."
apt install -y curl wget git unzip htop fail2ban logrotate cron ufw bc \
    software-properties-common apt-transport-https ca-certificates \
    gnupg lsb-release
echo "SUCCESS: Essential packages installed"

# Phase 2: Security Configuration
echo ""
echo "Phase 2: Security Configuration"
echo "-------------------------------"

# Configure UFW Firewall
echo "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "SUCCESS: UFW firewall configured and enabled"

# Configure Fail2Ban using repo files
echo "Configuring Fail2Ban..."
systemctl enable fail2ban
systemctl start fail2ban

# Use configuration files from this repo
cp "$SCRIPT_DIR/jail.local" /etc/fail2ban/jail.local
cp "$SCRIPT_DIR/caddy-auth.conf" /etc/fail2ban/filter.d/caddy-auth.conf
systemctl restart fail2ban
echo "SUCCESS: Fail2Ban configured with custom rules"

# Phase 3: Web Server Installation
echo ""
echo "Phase 3: Web Server Installation"
echo "--------------------------------"

# Install Caddy
echo "Installing Caddy web server..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy -y
systemctl enable caddy
systemctl start caddy
echo "SUCCESS: Caddy installed and started"

# Install PHP 8.2 and required modules
echo "Installing PHP 8.2 and modules..."
apt install -y php8.2-fpm php8.2-cli php8.2-curl php8.2-gd php8.2-mbstring \
    php8.2-xml php8.2-zip php8.2-intl php8.2-bcmath php8.2-yaml \
    php8.2-opcache php8.2-readline

# Configure PHP for better performance and security
echo "Optimizing PHP configuration..."
PHP_INI="/etc/php/8.2/fpm/php.ini"
sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 5M/' "$PHP_INI"
sed -i 's/post_max_size = 8M/post_max_size = 6M/' "$PHP_INI"
sed -i 's/memory_limit = 128M/memory_limit = 256M/' "$PHP_INI"
sed -i 's/max_execution_time = 30/max_execution_time = 300/' "$PHP_INI"
sed -i 's/max_input_vars = 1000/max_input_vars = 3000/' "$PHP_INI"
sed -i 's/;opcache.enable=1/opcache.enable=1/' "$PHP_INI"
sed -i 's/;opcache.memory_consumption=128/opcache.memory_consumption=128/' "$PHP_INI"

systemctl enable php8.2-fpm
systemctl restart php8.2-fpm
echo "SUCCESS: PHP 8.2 installed and optimized"

# Phase 4: Static Site Generator
echo ""
echo "Phase 4: Static Site Generator"
echo "------------------------------"

# Install Hugo
echo "Installing Hugo (latest extended version)..."
HUGO_VERSION=$(curl -s https://api.github.com/repos/gohugoio/hugo/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
echo "Installing Hugo version: $HUGO_VERSION"
wget -O /tmp/hugo.deb "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.deb"
dpkg -i /tmp/hugo.deb
rm /tmp/hugo.deb
echo "SUCCESS: Hugo $HUGO_VERSION installed"

# Phase 5: CMS and Directory Structure
echo ""
echo "Phase 5: CMS and Directory Structure"
echo "------------------------------------"

# Create directory structure
echo "Creating directory structure..."
mkdir -p /var/www /var/backups/sites /var/backups/server /var/log/forms /opt/templates
echo "SUCCESS: Directory structure created"

# Download and setup Grav CMS (core version, no admin)
echo "Installing Grav CMS core..."
cd /tmp
wget https://getgrav.org/download/core/grav/latest -O grav-core.zip
unzip grav-core.zip
mv grav /var/www/cms
chown -R www-data:www-data /var/www/cms
chmod -R 755 /var/www/cms

# Install essential Grav plugins (no admin)
echo "Installing Grav plugins..."
cd /var/www/cms
sudo -u www-data php bin/gpm install form -y
sudo -u www-data php bin/gpm install email -y
sudo -u www-data php bin/gpm install email-postmark -y
sudo -u www-data php bin/gpm install table-importer -y
echo "SUCCESS: Grav CMS and plugins installed"

# Create templates
echo "Setting up site templates..."

# Hugo template with Clarity theme
cd /opt/templates
hugo new site hugo-template
cd hugo-template
git init
git submodule add https://github.com/chipzoller/hugo-clarity themes/clarity
cp themes/clarity/exampleSite/config/_default/* config/_default/ 2>/dev/null || true
hugo

# Grav template (clean copy)
cp -r /var/www/cms /opt/templates/grav-template
cd /opt/templates/grav-template
rm -rf logs/* cache/* tmp/* backup/* 2>/dev/null || true
echo "SUCCESS: Site templates created"

# Phase 6: Form Handler and Management Scripts
echo ""
echo "Phase 6: Form Handler and Management Scripts"
echo "--------------------------------------------"

# Install form handler from repo
echo "Installing form handler..."
cp "$SCRIPT_DIR/form-handler.php" /var/www/form-handler.php
chmod 644 /var/www/form-handler.php
echo "SUCCESS: Form handler installed"

# Install management scripts from repo
echo "Installing management scripts..."
cp "$SCRIPT_DIR/create-site.sh" /root/
cp "$SCRIPT_DIR/backup-sites.sh" /root/
cp "$SCRIPT_DIR/server-monitor.sh" /root/
cp "$SCRIPT_DIR/server-update.sh" /root/
cp "$SCRIPT_DIR/form-secrets.template" /root/.form-secrets

chmod +x /root/*.sh
chmod 600 /root/.form-secrets
echo "SUCCESS: Management scripts installed"

# Install Caddy configuration from repo
echo "Installing Caddy configuration..."
cp "$SCRIPT_DIR/caddyfile.template" /etc/caddy/Caddyfile

# Update email in Caddyfile (prompt user)
echo ""
read -p "Enter your email for SSL certificates (e.g., admin@yourdomain.com): " USER_EMAIL
if [ -n "$USER_EMAIL" ]; then
    sed -i "s/admin@yourdomain.com/$USER_EMAIL/" /etc/caddy/Caddyfile
    echo "SUCCESS: SSL email set to: $USER_EMAIL"
fi

# Test and reload Caddy
if caddy validate --config /etc/caddy/Caddyfile; then
    systemctl reload caddy
    echo "SUCCESS: Caddy configuration loaded successfully"
else
    echo "ERROR: Caddy configuration error - check manually"
fi

# Phase 7: Automation and Monitoring
echo ""
echo "Phase 7: Automation and Monitoring"
echo "----------------------------------"

# Set up log rotation
echo "Configuring log rotation..."
cp "$SCRIPT_DIR/logrotate-caddy-sites" /etc/logrotate.d/caddy-sites
echo "SUCCESS: Log rotation configured"

# Set up cron jobs
echo "Installing automated tasks..."
(crontab -l 2>/dev/null; echo "0 2 * * * /root/backup-sites.sh >/dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "*/15 * * * * /root/server-monitor.sh >/dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "0 4 * * 0 /root/server-update.sh >/dev/null 2>&1") | crontab -
echo "SUCCESS: Automated tasks scheduled"

# Set up bash aliases
echo "Installing command aliases..."
cat >> /root/.bashrc << 'EOF'

# Alpha Omega Strategies Server Management
alias create-site='/root/create-site.sh'
alias backup-sites='/root/backup-sites.sh'
alias update-server='/root/update-server.sh'
alias monitor-server='tail -f /var/log/server-monitor.log'
alias check-sites='ls -la /var/www/'
alias caddy-reload='caddy reload --config /etc/caddy/Caddyfile'
alias caddy-logs='journalctl -u caddy -f'
EOF
echo "SUCCESS: Command aliases installed"

# Phase 8: Final Configuration
echo ""
echo "Phase 8: Final Configuration"
echo "----------------------------"

# Set final permissions
echo "Setting final permissions..."
chown -R www-data:www-data /var/www
chmod -R 755 /var/www
chmod 644 /var/www/form-handler.php
echo "SUCCESS: Permissions set correctly"

# Copy config files to /opt for easy access
echo "Setting up configuration access..."
mkdir -p /opt/server-configs
cp -r "$SCRIPT_DIR"/* /opt/server-configs/
echo "SUCCESS: Configuration files accessible at /opt/server-configs"

# Final status check
echo ""
echo "Verifying installation..."
CADDY_STATUS=$(systemctl is-active caddy)
PHP_STATUS=$(systemctl is-active php8.2-fpm)
FAIL2BAN_STATUS=$(systemctl is-active fail2ban)

echo "STATUS: Caddy: $CADDY_STATUS"
echo "STATUS: PHP-FPM: $PHP_STATUS"
echo "STATUS: Fail2Ban: $FAIL2BAN_STATUS"

# Server cleanup
apt autoremove -y && apt autoclean

# Get server IP for final instructions
SERVER_IP=$(curl -s http://ipv4.icanhazip.com/ || echo "YOUR-SERVER-IP")

echo ""
echo "========================================="
echo "========================================="
echo "SERVER SETUP COMPLETED SUCCESSFULLY!"
echo "========================================="
echo ""
echo "SERVICES INSTALLED:"
echo "   - Caddy web server with auto-SSL"
echo "   - PHP 8.2 FPM optimized for performance"
echo "   - Hugo static site generator"
echo "   - Grav CMS (core + essential plugins)"
echo "   - Universal form handler with Postmark/B2 integration"
echo "   - Automated backups, monitoring, and updates"
echo "   - Security hardening (UFW + Fail2Ban)"
echo ""
echo "AVAILABLE COMMANDS:"
echo "   - create-site domain.com [grav|hugo]"
echo "   - backup-sites"
echo "   - update-server"  
echo "   - monitor-server"
echo "   - check-sites"
echo ""
echo "ACCESS YOUR SERVER:"
echo "   - Default Grav CMS: http://$SERVER_IP"
echo "   - Form handler: http://$SERVER_IP/form-handler.php"
echo "   - Server health: http://$SERVER_IP/health"
echo ""
echo "NEXT STEPS:"
echo "   1. Configure API credentials: nano /root/.form-secrets"
echo "   2. Create your first site: create-site yourdomain.com grav"
echo "   3. Point DNS to: $SERVER_IP"
echo "   4. SSL certificates will generate automatically"
echo ""
echo "FILE LOCATIONS:"
echo "   - Sites: /var/www/"
echo "   - Configs: /opt/server-configs/"
echo "   - Logs: /var/log/"
echo "   - Backups: /var/backups/sites/"
echo ""
echo "MANAGEMENT:"
echo "   - Edit sites via WinSCP at /var/www/sitename/user/pages/"
echo "   - Form submissions logged to /var/log/forms/"
echo "   - Daily backups at 2 AM (14-day retention)"
echo "   - Server monitoring every 15 minutes"
echo ""
echo "========================================="
echo "Alpha Omega Strategies server is ready!"
echo "========================================"
