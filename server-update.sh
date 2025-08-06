#!/bin/bash
echo "Starting server maintenance: $(date)"
apt update && apt upgrade -y && apt autoremove -y && apt autoclean

# Check if reboot is needed
if [ -f /var/run/reboot-required ]; then
    echo "REBOOT REQUIRED after updates"
fi

# Restart key services after updates
systemctl restart nginx php8.3-fpm mariadb

echo "Maintenance completed: $(date)"
EOF