#!/bin/bash

# Simple server monitoring
DATE=$(date)
HOSTNAME=$(hostname)

# Check disk space
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')

# Check memory usage
MEM_USAGE=$(free | grep Mem | awk '{printf "%.2f", ($3/$2) * 100.0}')

# Check load average
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}')

# Check if services are running
CADDY_STATUS=$(systemctl is-active caddy)
PHP_STATUS=$(systemctl is-active php8.2-fpm)
FAIL2BAN_STATUS=$(systemctl is-active fail2ban)

# Log to file
LOG_FILE="/var/log/server-monitor.log"
echo "[$DATE] Disk: ${DISK_USAGE}% | Memory: ${MEM_USAGE}% | Load: ${LOAD_AVG} | Caddy: $CADDY_STATUS | PHP: $PHP_STATUS | Fail2Ban: $FAIL2BAN_STATUS" >> $LOG_FILE

# Alert if disk usage is over 90%
if [ $DISK_USAGE -gt 90 ]; then
    echo "WARNING: Disk usage is at ${DISK_USAGE}%" >> $LOG_FILE
fi

# Alert if memory usage is over 90%
if [ $(echo "$MEM_USAGE > 90" | bc -l) -eq 1 ]; then
    echo "WARNING: Memory usage is at ${MEM_USAGE}%" >> $LOG_FILE
fi
