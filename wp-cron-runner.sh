#!/bin/bash

# WordPress Cron Runner - handles all sites
for site_dir in /var/www/*/; do
    if [ -f "$site_dir/wp-config.php" ]; then
        domain=$(basename "$site_dir")
        cd "$site_dir"
        /usr/local/bin/wp cron event run --due-now --allow-root >/dev/null 2>&1
    fi
done
