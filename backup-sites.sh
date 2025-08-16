#!/bin/bash

# Automated backup script for Alpha Omega Strategies server
# Backs up all sites, databases, and configurations
# Keeps 14 days of backups as specified

set -e

# Configuration
BACKUP_DIR="/var/backups/sites"
DATE=$(date +%Y-%m-%d_%H-%M-%S)
KEEP_DAYS=14
LOG_FILE="/var/log/backup.log"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "Starting backup process..."

# Create backup directory for this run
CURRENT_BACKUP="$BACKUP_DIR/$DATE"
mkdir -p "$CURRENT_BACKUP"

# Track backup success
BACKUP_SUCCESS=true

# Backup each website
log_message "Backing up websites..."
SITE_COUNT=0

for SITE_PATH in /var/www/*/; do
    if [ -d "$SITE_PATH" ]; then
        SITENAME=$(basename "$SITE_PATH")
        
        # Skip if it's just the form handler
        if [ "$SITENAME" = "form-handler.php" ]; then
            continue
        fi
        
        log_message "Backing up site: $SITENAME"
        
        # Create compressed archive
        if tar -czf "$CURRENT_BACKUP/${SITENAME}.tar.gz" -C "/var/www" "$SITENAME" 2>/dev/null; then
            SITE_SIZE=$(du -h "$CURRENT_BACKUP/${SITENAME}.tar.gz" | cut -f1)
            log_message "  ✓ $SITENAME backed up successfully ($SITE_SIZE)"
            ((SITE_COUNT++))
        else
            log_message "  ✗ Failed to backup $SITENAME"
            BACKUP_SUCCESS=false
        fi
    fi
done

# Backup Caddy configuration
log_message "Backing up Caddy configuration..."
if cp /etc/caddy/Caddyfile "$CURRENT_BACKUP/" 2>/dev/null; then
    log_message "  ✓ Caddyfile backed up successfully"
else
    log_message "  ✗ Failed to backup Caddyfile"
    BACKUP_SUCCESS=false
fi

# Backup form handler
log_message "Backing up form handler..."
if cp /var/www/form-handler.php "$CURRENT_BACKUP/" 2>/dev/null; then
    log_message "  ✓ Form handler backed up successfully"
else
    log_message "  ✗ Failed to backup form handler"
    BACKUP_SUCCESS=false
fi

# Backup server configuration files
log_message "Backing up server configurations..."
CONFIG_BACKUP="$CURRENT_BACKUP/server-configs"
mkdir -p "$CONFIG_BACKUP"

# List of important config files to backup
CONFIG_FILES=(
    "/etc/fail2ban/jail.local"
    "/etc/fail2ban/filter.d/caddy-auth.conf"
    "/etc/logrotate.d/caddy-sites"
    "/root/.form-secrets"
    "/etc/php/8.2/fpm/php.ini"
)

for CONFIG_FILE in "${CONFIG_FILES[@]}"; do
    if [ -f "$CONFIG_FILE" ]; then
        BASENAME=$(basename "$CONFIG_FILE")
        if cp "$CONFIG_FILE" "$CONFIG_BACKUP/$BASENAME" 2>/dev/null; then
            log_message "  ✓ $BASENAME backed up"
        else
            log_message "  ✗ Failed to backup $BASENAME"
        fi
    fi
done

# Backup form submission logs (last 30 days only to manage size)
log_message "Backing up recent form logs..."
LOGS_BACKUP="$CURRENT_BACKUP/form-logs"
mkdir -p "$LOGS_BACKUP"

if [ -d "/var/log/forms" ]; then
    # Find and copy logs from last 30 days
    find /var/log/forms -name "*.log" -mtime -30 -exec cp --parents {} "$LOGS_BACKUP/" \; 2>/dev/null || true
    LOG_COUNT=$(find "$LOGS_BACKUP" -name "*.log" | wc -l)
    log_message "  ✓ $LOG_COUNT recent form log files backed up"
fi

# Create backup manifest
cat > "$CURRENT_BACKUP/backup-manifest.txt" << EOF
Alpha Omega Strategies Server Backup
Generated: $(date)
Backup Directory: $CURRENT_BACKUP

Sites Backed Up: $SITE_COUNT
$(ls -la "$CURRENT_BACKUP"/*.tar.gz 2>/dev/null || echo "No site archives found")

Configuration Files:
$(ls -la "$CONFIG_BACKUP"/ 2>/dev/null || echo "No config files found")

Form Logs:
Recent logs from last 30 days backed up to form-logs/

Total Backup Size: $(du -sh "$CURRENT_BACKUP" | cut -f1)
EOF

# Clean up old backups
log_message "Cleaning up old backups (keeping $KEEP_DAYS days)..."
REMOVED_COUNT=0

find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +$KEEP_DAYS -name "20*" | while read OLD_BACKUP; do
    if rm -rf "$OLD_BACKUP" 2>/dev/null; then
        log_message "  ✓ Removed old backup: $(basename "$OLD_BACKUP")"
        ((REMOVED_COUNT++))
    else
        log_message "  ✗ Failed to remove: $(basename "$OLD_BACKUP")"
    fi
done

# Calculate final statistics
TOTAL_SIZE=$(du -sh "$CURRENT_BACKUP" | cut -f1)
AVAILABLE_BACKUPS=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" | wc -l)

# Final status
if [ "$BACKUP_SUCCESS" = true ]; then
    log_message "Backup completed successfully!"
    log_message "  Sites backed up: $SITE_COUNT"
    log_message "  Total size: $TOTAL_SIZE"
    log_message "  Available backups: $AVAILABLE_BACKUPS"
    log_message "  Location: $CURRENT_BACKUP"
    
    # Update latest symlink for easy access
    ln -sfn "$CURRENT_BACKUP" "$BACKUP_DIR/latest"
    
    exit 0
else
    log_message "Backup completed with errors - check log for details"
    exit 1
fi
