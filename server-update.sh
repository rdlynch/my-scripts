#!/bin/bash
# Weekly OS and package maintenance for Debian 12
# Safe for unattended use via systemd timer (runs Sun 04:00 from server-setup.sh)
#
# - Full upgrade with noninteractive apt
# - Keeps existing config files by default
# - Restarts key services (Caddy, PHP-FPM, Fail2ban) post-upgrade
# - Detects when a reboot is required and schedules it (configurable)
# - Writes a simple log and prevents overlapping runs

set -euo pipefail
trap 'echo "ERROR: server-update failed at line $LINENO" >&2' ERR

# ---------- Config ----------
LOG_FILE="/var/log/aos-update.log"
ALLOW_REBOOT="${ALLOW_REBOOT:-yes}"    # set to "no" to never reboot automatically
REBOOT_DELAY_MIN="${REBOOT_DELAY_MIN:-2}"  # minutes before reboot if needed
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive
UMASK_VALUE="027"

# ---------- Helpers ----------
log() { echo "$(date -Is) $*" | tee -a "$LOG_FILE" ; }
ensure_dir() { install -d -m "$2" "$1"; }

# Simple kernel-reboot detection:
# If /boot has a newer kernel than the one running, we should reboot.
kernel_reboot_required() {
  local current latest
  current="$(uname -r)"
  latest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#^/boot/vmlinuz-##' | sort -V | tail -n1 || true)"
  [[ -n "$latest" && "$latest" != "$current" ]]
}

file_reboot_required() {
  [[ -f /var/run/reboot-required ]] || [[ -f /run/reboot-required ]]
}

# ---------- Main ----------
# Single-run lock
exec 9>/var/lock/server-update.lock
if ! flock -n 9; then
  echo "$(date -Is) Another update run is in progress; exiting" | tee -a "$LOG_FILE"
  exit 0
fi

umask "$UMASK_VALUE"
ensure_dir "$(dirname "$LOG_FILE")" 755
: > "$LOG_FILE"

log "Starting weekly maintenance"

# Refresh package lists
log "apt-get update"
apt-get update -y >>"$LOG_FILE" 2>&1

# Full upgrade, keep existing configs unless maintainer changes are safe
log "apt-get full-upgrade"
apt-get full-upgrade "${APT_OPTS[@]}" >>"$LOG_FILE" 2>&1

# Clean up residuals and old caches
log "apt-get autoremove --purge"
apt-get autoremove --purge -y >>"$LOG_FILE" 2>&1 || true
log "apt-get autoclean"
apt-get autoclean -y >>"$LOG_FILE" 2>&1 || true

# Reload systemd units in case packages added services
systemctl daemon-reload || true

# Restart key services to pick up new libraries
# Do not hard-restart Caddy unless needed; a reload is usually enough.
log "Refreshing services"
systemctl try-restart php8.2-fpm.service || true
if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  systemctl reload caddy || true
else
  # If validation fails, do not reload to avoid downtime
  log "WARNING: Caddyfile validation failed; skipping reload"
fi
systemctl reload fail2ban || true

# Determine if reboot is needed
NEED_REBOOT="no"
if file_reboot_required || kernel_reboot_required; then
  NEED_REBOOT="yes"
fi

if [[ "$NEED_REBOOT" == "yes" ]]; then
  log "Reboot required"
  if [[ "$ALLOW_REBOOT" == "yes" ]]; then
    log "Scheduling reboot in ${REBOOT_DELAY_MIN} minute(s)"
    /sbin/shutdown -r +"$REBOOT_DELAY_MIN" "AOS weekly maintenance reboot" || {
      log "Failed to schedule reboot; please reboot manually"
      exit 1
    }
  else
    log "AUTO-REBOOT DISABLED. Please reboot manually at your convenience."
  fi
else
  log "No reboot required"
fi

log "Weekly maintenance completed"
exit 0
