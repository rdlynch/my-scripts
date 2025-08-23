#!/bin/bash
# Debian 12 production setup for Caddy + PHP-FPM + Hugo (artifacts only) and per-site Grav
# Usage: sudo ./server-setup.sh
# Repo must be cloned at /opt/server-scripts before running.

set -euo pipefail
trap 'echo "ERROR: Setup failed at line $LINENO"; exit 1' ERR

# ---- Config -------------------------------------------------------------------
AOS_REPO_DIR="/opt/server-scripts"
AOS_LOG="/var/log/aos-setup.log"
AOS_TIMEZONE="America/Chicago"

SITES_DIR="/var/www"
BACKUP_DIR="/var/backups/sites"
FORM_LOG_DIR="/var/log/forms"          # PHP form-handler writes here
RATE_CACHE_DIR="/var/cache/aos-forms"  # per-IP rate limit cache
SCRIPT_BIN_DIR="/usr/local/sbin"
WWW_USER="www-data"
WWW_GROUP="www-data"

CREATE_SWAP="yes"
SWAP_FILE="/swapfile"
SWAP_SIZE="4G"

ENABLE_UFW="yes"
SSH_PORT="${SSH_PORT:-22}"

# ---- Helpers ------------------------------------------------------------------
log() { echo "$(date -Is) $*" | tee -a "$AOS_LOG" ; }
ensure_dir() { install -d -m "$2" "$1"; }
file_has_line() { grep -qsF "$2" "$1"; }
require_root() { [[ $EUID -eq 0 ]] || { echo "Please run as root" >&2; exit 1; }; }
require_repo() { [[ -d "$AOS_REPO_DIR" ]] || { echo "Repository not found at $AOS_REPO_DIR" >&2; exit 1; }; }

# ---- Start --------------------------------------------------------------------
require_root
require_repo
ensure_dir "$(dirname "$AOS_LOG")" 755
: > "$AOS_LOG"

log "Alpha Omega Strategies server setup starting"

export DEBIAN_FRONTEND=noninteractive

log "Setting timezone to $AOS_TIMEZONE"
timedatectl set-timezone "$AOS_TIMEZONE" || true
systemctl enable --now systemd-timesyncd.service

log "apt update and base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget unzip tar gnupg ufw fail2ban \
  software-properties-common apt-transport-https lsb-release \
  unattended-upgrades logrotate jq zip bzip2 rsync \
  php8.2-cli php8.2-fpm php8.2-curl php8.2-xml php8.2-zip php8.2-mbstring \
  php8.2-gd php8.2-intl php8.2-bcmath php8.2-opcache php-apcu

# Optional but beneficial for Grav if available
if apt-cache show php8.2-yaml >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends php8.2-yaml
elif apt-cache show php-yaml >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends php-yaml
else
  log "YAML PHP extension not available; continuing"
fi
phpenmod apcu || true
echo "apc.enable_cli=1" > /etc/php/8.2/cli/conf.d/20-apcu.ini

# Swap (idempotent)
if [[ "$CREATE_SWAP" == "yes" ]]; then
  if [[ ! -f "$SWAP_FILE" ]]; then
    log "Creating swap $SWAP_FILE $SWAP_SIZE"
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    printf "vm.swappiness=10\nvm.vfs_cache_pressure=50\n" >/etc/sysctl.d/99-aos.conf
    sysctl --system >/dev/null
  else
    log "Swap already present"
  fi
fi

# UFW
if [[ "$ENABLE_UFW" == "yes" ]]; then
  log "Configuring UFW"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$SSH_PORT"/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
fi

# SSH hardening
log "Hardening SSH"
SSHD=/etc/ssh/sshd_config
sed -i 's/^[# ]*PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD"
sed -i 's/^[# ]*PermitRootLogin .*/PermitRootLogin prohibit-password/' "$SSHD"
if ! file_has_line "$SSHD" "ClientAliveInterval 300"; then
  printf "\nClientAliveInterval 300\nClientAliveCountMax 2\n" >> "$SSHD"
fi
systemctl reload ssh || true

# Fail2ban
log "Configuring Fail2ban"
ensure_dir /etc/fail2ban/jail.d 755
if [[ -f "$AOS_REPO_DIR/jail.local" ]]; then
  install -m 0644 "$AOS_REPO_DIR/jail.local" /etc/fail2ban/jail.d/aos.local
fi
# Correct location for Caddy JSON filter
if [[ -f "$AOS_REPO_DIR/caddy-auth.conf" ]]; then
  install -m 0644 "$AOS_REPO_DIR/caddy-auth.conf" /etc/fail2ban/filter.d/caddy-auth.conf
fi
systemctl enable --now fail2ban

# Unattended upgrades
log "Enabling unattended-upgrades"
dpkg-reconfigure --priority=low unattended-upgrades || true
cat >/etc/apt/apt.conf.d/51aos-unattended.conf <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF

# Caddy (vendor repo)
if ! command -v caddy >/dev/null 2>&1; then
  log "Installing Caddy"
  apt-get install -y debian-keyring debian-archive-keyring
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y
  apt-get install -y caddy
else
  log "Caddy already installed"
fi

# Ensure Caddy log dir exists
install -d -o caddy -g caddy -m 755 /var/log/caddy

# PHP-FPM tuning for 4GB node
log "Tuning PHP-FPM"
PHP_INI=/etc/php/8.2/fpm/php.ini
POOL_CONF=/etc/php/8.2/fpm/pool.d/www.conf
sed -i 's/^;*opcache.enable=.*/opcache.enable=1/' "$PHP_INI"
sed -i 's/^;*opcache.memory_consumption=.*/opcache.memory_consumption=128/' "$PHP_INI"
sed -i 's/^;*opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$PHP_INI"
sed -i 's/^;*cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/' "$PHP_INI"
# realpath cache helps Grav/Composer autoloaders
if ! grep -q '^realpath_cache_size' "$PHP_INI"; then echo 'realpath_cache_size = 4096k' >> "$PHP_INI"; else sed -i 's/^;*realpath_cache_size.*/realpath_cache_size = 4096k/' "$PHP_INI"; fi
if ! grep -q '^realpath_cache_ttl' "$PHP_INI"; then echo 'realpath_cache_ttl = 600' >> "$PHP_INI"; else sed -i 's/^;*realpath_cache_ttl.*/realpath_cache_ttl = 600/' "$PHP_INI"; fi
# FPM pool (conservative)
sed -i 's/^pm = .*/pm = dynamic/' "$POOL_CONF"
sed -i 's/^pm.max_children = .*/pm.max_children = 12/' "$POOL_CONF"
sed -i 's/^pm.start_servers = .*/pm.start_servers = 3/' "$POOL_CONF"
sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "$POOL_CONF"
sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 6/' "$POOL_CONF"
systemctl enable --now php8.2-fpm

# Standard directories
log "Creating standard directories"
ensure_dir "$SITES_DIR" 755
ensure_dir "$BACKUP_DIR" 750
# Forms log dir: group www-data, setgid so new files inherit group
install -d -m 2750 -o root -g www-data "$FORM_LOG_DIR"
# Rate limit cache for form handler
install -d -m 2770 -o root -g www-data "$RATE_CACHE_DIR"
chown -R "$WWW_USER:$WWW_GROUP" "$SITES_DIR"
chown -R root:root "$BACKUP_DIR"

# Deploy Caddyfile template if present
log "Deploying Caddyfile template (if present)"
if [[ -f "$AOS_REPO_DIR/caddyfile.template" ]]; then
  install -m 0644 "$AOS_REPO_DIR/caddyfile.template" /etc/caddy/Caddyfile
  if caddy validate --config /etc/caddy/Caddyfile; then
    systemctl enable --now caddy
    systemctl reload caddy || true
  else
    log "WARNING: Caddyfile validation failed; leaving current config in place"
  fi
fi

# Install form handler and secrets template if present
log "Installing form handler and secrets (if present)"
if [[ -f "$AOS_REPO_DIR/form-handler.php" ]]; then
  install -m 0644 "$AOS_REPO_DIR/form-handler.php" "$SITES_DIR"/form-handler.php
  chown "$WWW_USER:$WWW_GROUP" "$SITES_DIR"/form-handler.php
fi
if [[ -f "$AOS_REPO_DIR/form-secrets.template" ]]; then
  install -m 0640 "$AOS_REPO_DIR/form-secrets.template" /etc/aos-form-secrets
  chgrp "$WWW_GROUP" /etc/aos-form-secrets || true
fi

# Logrotate for Caddy rotated files
if [[ -f "$AOS_REPO_DIR/logrotate-caddy-sites" ]]; then
  log "Installing logrotate policy for Caddy rotated logs"
  install -m 0644 "$AOS_REPO_DIR/logrotate-caddy-sites" /etc/logrotate.d/caddy-sites
fi

# Expose helper scripts in PATH (symlinks)
log "Linking management scripts into $SCRIPT_BIN_DIR"
install -d -m 755 "$SCRIPT_BIN_DIR"
ln -sf "$AOS_REPO_DIR/create-site.sh"    "$SCRIPT_BIN_DIR/create-site"
ln -sf "$AOS_REPO_DIR/backup-sites.sh"   "$SCRIPT_BIN_DIR/backup-sites"
ln -sf "$AOS_REPO_DIR/server-update.sh"  "$SCRIPT_BIN_DIR/server-update"
ln -sf "$AOS_REPO_DIR/server-monitor.sh" "$SCRIPT_BIN_DIR/server-monitor"

# Systemd units and timers
log "Creating systemd services and timers"
cat >/etc/systemd/system/aos-backup.service <<EOF
[Unit]
Description=AOS site backups
[Service]
Type=oneshot
ExecStart=$SCRIPT_BIN_DIR/backup-sites
EOF

cat >/etc/systemd/system/aos-backup.timer <<'EOF'
[Unit]
Description=Run AOS site backups daily at 02:00
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/aos-update.service <<EOF
[Unit]
Description=AOS weekly server update
[Service]
Type=oneshot
ExecStart=$SCRIPT_BIN_DIR/server-update
EOF

cat >/etc/systemd/system/aos-update.timer <<'EOF'
[Unit]
Description=Run AOS server updates weekly Sun 04:00
[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/aos-monitor.service <<EOF
[Unit]
Description=AOS server monitor
[Service]
Type=oneshot
ExecStart=$SCRIPT_BIN_DIR/server-monitor
EOF

cat >/etc/systemd/system/aos-monitor.timer <<'EOF'
[Unit]
Description=Run AOS monitor every 15 minutes
[Timer]
OnCalendar=*:0/15
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now aos-backup.timer aos-update.timer aos-monitor.timer

# Kernel/network hardening (safe defaults)
log "Applying basic sysctl hardening"
cat >/etc/sysctl.d/60-aos-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
sysctl --system >/dev/null

# Final verification
log "Verifying services"
systemctl is-active --quiet caddy && log "Caddy active"
systemctl is-active --quiet php8.2-fpm && log "PHP-FPM active"
systemctl is-enabled --quiet aos-backup.timer && log "Backup timer enabled"
systemctl is-enabled --quiet aos-update.timer && log "Update timer enabled"
systemctl is-enabled --quiet aos-monitor.timer && log "Monitor timer enabled"

echo "Setup complete."
echo "Sites: $SITES_DIR"
echo "Backups: $BACKUP_DIR"
echo "Form logs: $FORM_LOG_DIR"
echo "Scripts in PATH: create-site, backup-sites, server-update, server-monitor"
