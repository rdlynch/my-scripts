#!/bin/bash
# Lightweight health monitor for Debian 12 on a 2 vCPU / 4 GB VPS
# Safe to run via systemd timer (every 15 minutes as configured)
# - Checks: Caddy, PHP-FPM, Fail2ban, UFW
# - Validates Caddyfile
# - Disk, inode, memory, swap, load (thresholds adjustable)
# - TLS cert expiry from Caddy storage
# - Large per-site log files
# Exit codes: 0 OK, 1 warnings, 2 critical

set -euo pipefail
trap 'echo "$(date -Is) ERROR: monitor failed at line $LINENO" | tee -a "$LOG_FILE"; exit 2' ERR

LOG_FILE="/var/log/aos-monitor.log"
SITES_DIR="/var/www"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_CERT_DIR="/var/lib/caddy"
CADDY_LOG_DIR="/var/log/caddy"

# Thresholds
WARN_DISK=80     # percent
CRIT_DISK=90
WARN_INODE=80    # percent
CRIT_INODE=90
WARN_MEM_MB=300  # available MB
CRIT_MEM_MB=150
WARN_SWAP_MB=256 # used MB
CRIT_SWAP_MB=512
LOG_WARN_BYTES=$((1024*1024*1024)) # 1 GiB single log file warning
CERT_WARN_DAYS=21
CERT_CRIT_DAYS=7

# Helpers
log() { echo "$(date -Is) $*" | tee -a "$LOG_FILE"; }
pct() { awk 'BEGIN{printf "%.0f",('"$1"'*100)/'"$2"'}'; }

ensure_log() { install -d -m 755 "$(dirname "$LOG_FILE")"; : > /dev/null; }

oklist=()
warnlist=()
critlist=()

add_ok()   { oklist+=("$1"); }
add_warn() { warnlist+=("$1"); }
add_crit() { critlist+=("$1"); }

check_service() {
  local svc="$1" title="$2"
  if systemctl is-active --quiet "$svc"; then
    add_ok "$title running"
  else
    # try a light restart; if it still fails, flag critical
    systemctl try-restart "$svc" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$svc"; then
      add_warn "$title was down, restarted"
    else
      add_crit "$title not running"
    fi
  fi
}

bytes_to_mb() { awk 'BEGIN{printf "%.0f",('"$1"'/1048576)}'; }

cert_days_left() {
  # Prints "CN daysleft" per cert, or nothing if openssl missing
  command -v openssl >/dev/null 2>&1 || return 0
  find "$CADDY_CERT_DIR" -type f -name '*.crt' 2>/dev/null | while read -r crt; do
    local end notafter tsnow tsend days cn
    notafter="$(openssl x509 -noout -enddate -in "$crt" 2>/dev/null | sed 's/notAfter=//')"
    [[ -n "$notafter" ]] || continue
    tsnow=$(date -u +%s)
    tsend=$(date -u -d "$notafter" +%s 2>/dev/null || echo 0)
    [[ "$tsend" -gt 0 ]] || continue
    days=$(( (tsend - tsnow) / 86400 ))
    cn="$(openssl x509 -noout -subject -in "$crt" 2>/dev/null | sed -n 's/^subject=.*CN=\([^/]*\).*$/\1/p')"
    echo "$cn $days"
  done
}

# Main
ensure_log

# Single-run lock
exec 9>/var/lock/server-monitor.lock
flock -n 9 || { log "Another monitor run is in progress, exiting"; exit 0; }

# Services
check_service caddy "Caddy"
check_service php8.2-fpm "PHP-FPM"
check_service fail2ban "Fail2ban"

# UFW status
if ufw status | grep -q "^Status: active"; then
  add_ok "UFW active"
else
  add_warn "UFW not active"
fi

# Caddyfile validation
if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  add_ok "Caddyfile valid"
else
  add_crit "Caddyfile validation failed"
fi

# Disk and inode checks for key mounts
for m in / /var /var/log /var/www /var/backups; do
  [[ -d "$m" ]] || continue
  read -r fs size used avail pcent mount <<<"$(df -P "$m" | awk 'NR==2{print $1,$2,$3,$4,$5,$6}')"
  p=${pcent%\%}
  if (( p >= CRIT_DISK )); then add_crit "Disk $m at ${p}%"; 
  elif (( p >= WARN_DISK )); then add_warn "Disk $m at ${p}%"; 
  else add_ok "Disk $m at ${p}%"; fi

  read -r ifs i_inodes i_used i_free ipcent imount <<<"$(df -Pi "$m" | awk 'NR==2{print $1,$2,$3,$4,$5,$6}')"
  ip=${ipcent%\%}
  if (( ip >= CRIT_INODE )); then add_crit "Inodes $m at ${ip}%"; 
  elif (( ip >= WARN_INODE )); then add_warn "Inodes $m at ${ip}%"; 
  else add_ok "Inodes $m at ${ip}%"; fi
done

# Memory and swap
read -r mem_total mem_free mem_avail <<<"$(awk '/MemTotal|MemFree|MemAvailable/ {gsub(/ kB/,""); a[$1]=$2} END{print a["MemTotal:"],a["MemFree:"],a["MemAvailable:"]}' /proc/meminfo)"
avail_mb=$(( mem_avail / 1024 ))
if (( avail_mb <= CRIT_MEM_MB )); then add_crit "Memory available ${avail_mb}MB"; 
elif (( avail_mb <= WARN_MEM_MB )); then add_warn "Memory available ${avail_mb}MB"; 
else add_ok "Memory available ${avail_mb}MB"; fi

read -r swap_total swap_used swap_free <<<"$(awk '/SwapTotal|SwapFree/ {gsub(/ kB/,""); a[$1]=$2} END{u=a["SwapTotal:"]-a["SwapFree:"]; printf "%s %s %s", a["SwapTotal:"], u, a["SwapFree:"]}' /proc/meminfo)"
swap_used_mb=$(( swap_used / 1024 ))
if (( swap_used_mb >= CRIT_SWAP_MB )); then add_warn "Swap used ${swap_used_mb}MB"; 
elif (( swap_used_mb >= WARN_SWAP_MB )); then add_warn "Swap used ${swap_used_mb}MB"; 
else add_ok "Swap used ${swap_used_mb}MB"; fi

# Load vs cores
cores=$(nproc)
la1=$(awk '{print int($1+0.5)}' /proc/loadavg)
# Rough guide: warn if 1-min load > 2x cores
if (( la1 > cores*2 )); then add_warn "High load 1m=${la1} cores=${cores}"; else add_ok "Load 1m=${la1} cores=${cores}"; fi

# TLS certificate expiry from Caddy storage
if [[ -d "$CADDY_CERT_DIR" ]] && command -v openssl >/dev/null 2>&1; then
  while read -r dom days; do
    [[ -n "$dom" && "$days" =~ ^-?[0-9]+$ ]] || continue
    if (( days <= CERT_CRIT_DAYS )); then
      add_crit "Cert for $dom expires in ${days} day(s)"
    elif (( days <= CERT_WARN_DAYS )); then
      add_warn "Cert for $dom expires in ${days} day(s)"
    else
      add_ok "Cert $dom ${days}d left"
    fi
  done < <(cert_days_left)
else
  add_warn "Cert check skipped (no openssl or cert store not found)"
fi

# Oversized log files (rotation sanity)
if [[ -d "$CADDY_LOG_DIR" ]]; then
  while IFS= read -r -d '' f; do
    sz=$(stat -c%s "$f")
    if (( sz > LOG_WARN_BYTES )); then
      add_warn "Large log $(basename "$f") $(bytes_to_mb "$sz")MB"
    fi
  done < <(find "$CADDY_LOG_DIR" -type f -name '*.log' -print0 2>/dev/null)
fi

# Fail2ban summary
if command -v fail2ban-client >/dev/null 2>&1; then
  if fail2ban-client ping >/dev/null 2>&1; then
    jails=$(fail2ban-client status 2>/dev/null | awk -F': ' '/Jail list:/ {print $2}')
    [[ -n "$jails" ]] && add_ok "Fail2ban jails: $jails" || add_warn "Fail2ban has no jails"
  else
    add_warn "Fail2ban not responding to client"
  fi
fi

# Summary and exit code
status=0
[[ ${#critlist[@]} -gt 0 ]] && status=2 || { [[ ${#warnlist[@]} -gt 0 ]] && status=1 || status=0; }

log "----- AOS monitor report begin -----"
if [[ ${#critlist[@]} -gt 0 ]]; then
  for m in "${critlist[@]}"; do log "CRIT: $m"; done
fi
if [[ ${#warnlist[@]} -gt 0 ]]; then
  for m in "${warnlist[@]}"; do log "WARN: $m"; done
fi
for m in "${oklist[@]}"; do log "OK: $m"; done
log "Status code: $status"
log "----- AOS monitor report end -----"

exit "$status"
