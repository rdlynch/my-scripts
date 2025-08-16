#!/bin/bash

# Backup all sites
BACKUP_DIR="/var/backups/sites"
DATE=$(date +%Y-%m-%d_%H-%M-%S)
KEEP_DAYS=14

echo "Starting site backups..."

# Create backup directory for today
mkdir -p "$BACKUP_DIR/$DATE"

# Backup each site
for SITE in /var/www/*/; do
    if [ -d "$SITE" ]; then
        SITENAME=$(basename "$SITE")
        echo "Backing up $SITENAME..."
        tar -czf "$BACKUP_DIR/$DATE/${SITENAME}.tar.gz" -C "/var/www" "$SITENAME"
    fi
done

# Backup Caddy configuration
cp /etc/caddy/Caddyfile "$BACKUP_DIR/$DATE/"

# Remove old backups
find "$BACKUP_DIR" -type d -mtime +$KEEP_DAYS -exec rm -rf {} +

echo "Backup completed: $BACKUP_DIR/$DATE"
