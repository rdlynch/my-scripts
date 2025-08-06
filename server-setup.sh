#!/bin/bash

# Automated WordPress Server Setup
# For use with cloud-init or manual execution

set -e  # Exit on any error

echo "Starting automated server setup..."

# Update the server
echo "Updating system packages..."
apt update && apt upgrade -y && apt autoremove -y && apt autoclean

# Set timezone
echo "Setting timezone..."
timedatectl set-timezone America/Chicago

# Create swap file
echo "Creating swap file..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Configure UFW
echo "Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

# Install and configure Fail2Ban
echo "Installing fail2ban..."
apt install fail2ban -y
systemctl enable fail2ban
systemctl start fail2ban

# Clone server management scripts from your repo
echo "Downloading server configuration files..."
cd /opt
git clone https://github.com/rdlynch/my-scripts.git server-configs

# Use your jail.local file
cp /opt/server-configs/jail.local /etc/fail2ban/jail.local
systemctl restart fail2ban

# Install Nginx
echo "Installing Nginx..."
apt install nginx -y
systemctl enable nginx
systemctl start nginx

# Set up Git-based 8G Firewall
echo "Setting up 8G Firewall..."
cd /opt
git clone https://github.com/t18d/nG-SetEnvIf.git
ln -s /opt/nG-SetEnvIf/8g-firewall.conf /etc/nginx/8g-firewall.conf

# Create WordPress-optimized template config from your repo
cp /opt/server-configs/wordpress-template /etc/nginx/sites-available/wordpress-template

# Remove default site, test configuration
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# Install PHP 8.3 and required modules
echo "Installing PHP 8.3..."
apt install php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml php8.3-zip php8.3-intl php8.3-bcmath php8.3-imagick -y

# Configure PHP for WordPress
sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 64M/' /etc/php/8.3/fpm/php.ini
sed -i 's/post_max_size = 8M/post_max_size = 64M/' /etc/php/8.3/fpm/php.ini
sed -i 's/memory_limit = 128M/memory_limit = 256M/' /etc/php/8.3/fpm/php.ini
sed -i 's/max_execution_time = 30/max_execution_time = 300/' /etc/php/8.3/fpm/php.ini
sed -i 's/max_input_vars = 1000/max_input_vars = 3000/' /etc/php/8.3/fpm/php.ini

# Enable and start PHP-FPM
systemctl enable php8.3-fpm
systemctl start php8.3-fpm
systemctl reload nginx

# Install MariaDB
echo "Installing MariaDB..."
apt install mariadb-server -y
systemctl enable mariadb
systemctl start mariadb

# Automated MariaDB security (replaces mysql_secure_installation)
echo "Securing MariaDB..."
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)

# Secure MariaDB installation automatically
mysql << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF

# Save root password securely
echo "MySQL root password: ${MYSQL_ROOT_PASSWORD}" > /root/.mysql_root_password
chmod 600 /root/.mysql_root_password

echo "MariaDB root password saved to /root/.mysql_root_password"

# Configure log rotation from your repo
echo "Setting up log rotation..."
cp /opt/server-configs/logrotate-nginx-wordpress /etc/logrotate.d/nginx-wordpress

# Install WP CLI
echo "Installing WP CLI..."
curl -O https://raw.githubusercontent.com/wp-cli/wp-cli/v2.10.0/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

# Install certbot
echo "Installing certbot..."
apt install certbot python3-certbot-nginx -y

# Copy server management scripts from your repo
cp /opt/server-configs/wp-cron-runner.sh /root/
cp /opt/server-configs/wp-clean-install.sh /root/
cp /opt/server-configs/server-update.sh /root/

chmod +x /root/wp-cron-runner.sh
chmod +x /root/wp-clean-install.sh  
chmod +x /root/server-update.sh

# Add WordPress cron to system crontab (non-interactive)
(crontab -l 2>/dev/null; echo "*/15 * * * * /root/wp-cron-runner.sh >/dev/null 2>&1") | crontab -



# WordPress Plugin Keys
cat > /root/.wp-secrets << 'EOF'
# WordPress Automation Secrets
# Keep this file secure (chmod 600)

POSTMARK_TOKEN="d14208f6-13ac-4df3-9e63-6666a24dca30"
WPVIVID_KEY="063d01eebf12184be0664791bb782df7"
EOF

chmod 600 /root/.wp-secrets

# Set up aliases (append to existing bashrc or create)
cat >> /root/.bashrc << 'EOF'

# Custom server management aliases
alias wp-clean='/root/wp-clean-install.sh'
alias server-update='/root/server-update.sh'
alias update-tools='/root/update-git-tools.sh'
EOF

echo ""
echo "========================================="
echo "Server setup completed successfully!"
echo "========================================="
echo "Services installed and configured:"
echo "- Nginx with 8G Firewall"
echo "- PHP 8.3 FPM"
echo "- MariaDB (root password in /root/.mysql_root_password)"
echo "- WP CLI"
echo "- Certbot for SSL"
echo "- Fail2ban"
echo "- UFW Firewall"
echo "- Log rotation"
echo "- WordPress cron automation"
echo ""
echo "Available commands:"
echo "- wp-clean domain.com (create WordPress site)"
echo "- server-update (update server)"
echo "- update-tools (update Git-based tools)"
echo "========================================"
