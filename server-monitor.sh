#!/bin/bash

# Server monitoring script for Alpha Omega Strategies
# Runs every 15 minutes via cron to track server health
# Logs to /var/log/server-monitor.log

# Configuration
LOG_FILE="/var/log/server-monitor.log"
ALERT_DISK_THRESHOLD=90
ALERT_MEMORY_THRESHOLD=90
ALERT_LOAD_THRESHOLD=4.0

# Get current timestamp
DATE=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

# Function to log messages
log_message() {
    echo "[$DATE] $1" >> "$LOG_FILE"
}

# Check disk space usage
get_disk_usage() {
    df -h / | awk 'NR==2 {print $5}' | sed 's/%//'
}

# Check memory usage percentage
get_memory_usage() {
    free | grep Mem | awk '{printf "%.1f", ($3/$2) * 100.0}'
}

# Check load average (1 minute)
get_load_average() {
    uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs
}

# Check if a service is running
check_service() {
    systemctl is-active "$1" 2>/dev/null || echo "inactive"
}

# Check if a port is listening
check_port() {
    if ss -tuln | grep -q ":$1 "; then
        echo "listening"
    else
        echo "not-listening"
    fi
}

# Get system metrics
DISK_USAGE=$(get_disk_usage)
MEMORY_USAGE=$(get_memory_usage)
LOAD_AVG=$(get_load_average)

# Check critical services
CADDY_STATUS=$(check_service caddy)
PHP_STATUS=$(check_service php8.2-fpm)
FAIL2BAN_STATUS=$(check_service fail2ban)
CRON_STATUS=$(check_service cron)

# Check ports
HTTP_PORT=$(check_port 80)
HTTPS_PORT=$(check_port 443)
SSH_PORT=$(check_port 22)

# Count active sites (directories in /var/www excluding form handler)
ACTIVE_SITES=$(find /var/www -maxdepth 1 -type d | grep -v "^/var/www$" | wc -l)

# Log basic status
log_message "STATS: Disk=${DISK_USAGE}% Memory=${MEMORY_USAGE}% Load=${LOAD_AVG} Sites=${ACTIVE_SITES} Services=[Caddy:${CADDY_STATUS} PHP:${PHP_STATUS} Fail2Ban:${FAIL2BAN_STATUS}] Ports=[80:${HTTP_PORT} 443:${HTTPS_PORT} 22:${SSH_PORT}]"

# Alert conditions
ALERTS_TRIGGERED=false

# Disk space alert
if [ "$DISK_USAGE" -gt "$ALERT_DISK_THRESHOLD" ]; then
    log_message "ALERT: High disk usage at ${DISK_USAGE}% (threshold: ${ALERT_DISK_THRESHOLD}%)"
    ALERTS_TRIGGERED=true
fi

# Memory usage alert
if [ "$(echo "$MEMORY_USAGE > $ALERT_MEMORY_THRESHOLD" | bc -l)" -eq 1 ]; then
    log_message "ALERT: High memory usage at ${MEMORY_USAGE}% (threshold: ${ALERT_MEMORY_THRESHOLD}%)"
    ALERTS_TRIGGERED=true
fi

# Load average alert
if [ "$(echo "$LOAD_AVG > $ALERT_LOAD_THRESHOLD" | bc -l)" -eq 1 ]; then
    log_message "ALERT: High load average at ${LOAD_AVG} (threshold: ${ALERT_LOAD_THRESHOLD})"
    ALERTS_TRIGGERED=true
fi

# Service status alerts
if [ "$CADDY_STATUS" != "active" ]; then
    log_message "ALERT: Caddy web server is not running (status: ${CADDY_STATUS})"
    ALERTS_TRIGGERED=true
fi

if [ "$PHP_STATUS" != "active" ]; then
    log_message "ALERT: PHP-FPM is not running (status: ${PHP_STATUS})"
    ALERTS_TRIGGERED=true
fi

if [ "$FAIL2BAN_STATUS" != "active" ]; then
    log_message "ALERT: Fail2Ban is not running (status: ${FAIL2BAN_STATUS})"
    ALERTS_TRIGGERED=true
fi

# Port alerts
if [ "$HTTP_PORT" != "listening" ]; then
    log_message "ALERT: HTTP port 80 not listening"
    ALERTS_TRIGGERED=true
fi

if [ "$HTTPS_PORT" != "listening" ]; then
    log_message "ALERT: HTTPS port 443 not listening"
    ALERTS_TRIGGERED=true
fi

if [ "$SSH_PORT" != "listening" ]; then
    log_message "ALERT: SSH port 22 not listening"
    ALERTS_TRIGGERED=true
fi

# Check for failed login attempts (if fail2ban is working)
if [ "$FAIL2BAN_STATUS" = "active" ]; then
    BANNED_IPS=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned:" | awk '{print $4}' || echo "0")
    if [ "$BANNED_IPS" -gt 0 ]; then
        log_message "INFO: Fail2Ban has $BANNED_IPS IP(s) currently banned"
    fi
fi

# Check certificate expiration for sites (once per day at 02:00)
CURRENT_HOUR=$(date +%H)
CURRENT_MINUTE=$(date +%M)
if [ "$CURRENT_HOUR" = "02" ] && [ "$CURRENT_MINUTE" -lt "15" ]; then
    log_message "INFO: Starting daily SSL certificate check"
    
    # Get all domains from Caddyfile
    if [ -f "/etc/caddy/Caddyfile" ]; then
        grep -E "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,} {" /etc/caddy/Caddyfile | awk '{print $1}' | while read DOMAIN; do
            if [ -n "$DOMAIN" ]; then
                # Check certificate expiration (30 days warning)
                CERT_DAYS=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep notAfter | cut -d= -f2 | xargs -I {} date -d "{}" +%s 2>/dev/null || echo "0")
                CURRENT_EPOCH=$(date +%s)
                
                if [ "$CERT_DAYS" -gt 0 ]; then
                    DAYS_UNTIL_EXPIRY=$(( (CERT_DAYS - CURRENT_EPOCH) / 86400 ))
                    
                    if [ "$DAYS_UNTIL_EXPIRY" -lt 30 ] && [ "$DAYS_UNTIL_EXPIRY" -gt 0 ]; then
                        log_message "ALERT: SSL certificate for $DOMAIN expires in $DAYS_UNTIL_EXPIRY days"
                        ALERTS_TRIGGERED=true
                    elif [ "$DAYS_UNTIL_EXPIRY" -le 0 ]; then
                        log_message "ALERT: SSL certificate for $DOMAIN has EXPIRED"
                        ALERTS_TRIGGERED=true
                    fi
                fi
            fi
        done
    fi
fi

# Check available updates (once per day at 03:00)
if [ "$CURRENT_HOUR" = "03" ] && [ "$CURRENT_MINUTE" -lt "15" ]; then
    log_message "INFO: Checking for available updates"
    
    # Check for package updates
    apt list --upgradable 2>/dev/null | grep -c upgradable | while read UPDATE_COUNT; do
        if [ "$UPDATE_COUNT" -gt 1 ]; then  # Subtract 1 for header line
            ACTUAL_UPDATES=$((UPDATE_COUNT - 1))
            log_message "INFO: $ACTUAL_UPDATES package updates available"
        fi
    done
    
    # Check Hugo version
    if command -v hugo >/dev/null 2>&1; then
        CURRENT_HUGO=$(hugo version 2>/dev/null | grep -o 'v[0-9.]*' | head -1 | sed 's/v//')
        LATEST_HUGO=$(curl -s https://api.github.com/repos/gohugoio/hugo/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//' 2>/dev/null || echo "unknown")
        
        if [ "$CURRENT_HUGO" != "$LATEST_HUGO" ] && [ "$LATEST_HUGO" != "unknown" ]; then
            log_message "INFO: Hugo update available: $CURRENT_HUGO -> $LATEST_HUGO"
        fi
    fi
fi

# Summary for this monitoring cycle
if [ "$ALERTS_TRIGGERED" = true ]; then
    log_message "SUMMARY: Monitoring completed with ALERTS - review above messages"
    exit 1
else
    # Only log summary every hour to reduce log size
    if [ "$(date +%M)" -lt "15" ]; then
        log_message "SUMMARY: All systems normal - $ACTIVE_SITES sites active"
    fi
    exit 0
fi
