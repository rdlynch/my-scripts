#!/bin/bash
# Back up all sites under /var/www to /var/backups/sites
# - Detects site type (Hugo vs Grav) automatically
# - Hugo: archives only /public (you build locally)
# - Grav: archives full site but excludes cache and site-level backups
# - Throttled with nice/ionice, single-run lock to avoid overlap
# - Verifies archive, writes SHA256, and prunes old backups
#
# Usage: backup-sites (run as root; invoked by systemd timer)

set -euo pipefail
trap 'echo "ERROR: backup failed at line $LINENO" >&2' ERR

# -------- Config --------
SITES_DIR="/var/www"
DEST_BASE="/var/backups/sites"
RETENTION_DAYS="${RETENTION_DAYS:-14}"      # delete archives older than N days
UMASK_VALUE="027"

# Compression: prefer zstd if available, else gzip
if command -v zstd >/dev/null 2>&1 && tar --help 2>&1 | grep -q -- '--zstd'; then
  TAR_COMP="--zstd"
  EXT="tar.zst"
  VERIFY_CMD() { zstd -t "$1" >/dev/null; }       # test archive
else
  TAR_COMP="--gzip"
  EXT="tar.gz"
  VERIFY_CMD() { gzip -t "$1" >/dev/null; }       # test via gzip
fi

# -------- Helpers --------
log() { echo "$(date -Is) $*"; }
ensure_dir() { install -d -m "$2" "$1"; }

# Detects Grav vs Hugo
# Grav: root contains index.php and user/
# Hugo: <site>/public exists and root does NOT contain index.php
detect_type() {
  local root="$1"
  if [[ -f "$root/index.php" && -d "$root/user" ]]; then
    echo "grav"
  elif [[ -d "$root/public" && ! -f "$root/index.php" ]]; then
    echo "hugo"
  else
    echo "unknown"
  fi
}

# Returns a space-separated list of --exclude patterns relative to /var/www
grav_excludes() {
  local domain="$1"
  # Exclude transient or redundant data
  echo "--exclude=${domain}/cache --exclude=${domain}/backup"
}

archive_site() {
  local domain="$1"
  local sroot="${SITES_DIR}/${domain}"
  local dest_dir="${DEST_BASE}/${domain}"
  ensure_dir "$dest_dir" 750

  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)

  local archive="${dest_dir}/${domain}-${ts}.${EXT}"
  local type
  type=$(detect_type "$sroot")

  case "$type" in
    hugo)
      if [[ ! -d "$sroot/public" ]]; then
        log "WARN: $domain looks like Hugo but public/ missing, skipping"
        return 0
      fi
      log "Backing up HUGO site $domain"
      ionice -c2 -n7 nice -n 10 \
        tar ${TAR_COMP} -cf "$archive" -C "$sroot" public
      ;;
    grav)
      log "Backing up GRAV site $domain"
      # Use -C /var/www so the archive contains "<domain>/*"
      # Exclude cache and site backups to reduce size
      local ex
      ex=$(grav_excludes "$domain")
      # shellcheck disable=SC2086
      ionice -c2 -n7 nice -n 10 \
        tar ${TAR_COMP} -cf "$archive" -C "$SITES_DIR" $ex "$domain"
      ;;
    *)
      log "INFO: $domain type unknown, skipping"
      return 0
      ;;
  esac

  # Verify archive and write checksum
  if VERIFY_CMD "$archive"; then
    sha256sum "$archive" > "${archive}.sha256"
    log "OK: $archive"
  else
    log "ERROR: verification failed for $archive"
    rm -f "$archive"
    return 1
  fi

  # Prune old archives for this domain
  find "$dest_dir" -type f -name "${domain}-*.tar.*" -mtime +"$RETENTION_DAYS" -print -delete || true
  find "$dest_dir" -type f -name "${domain}-*.sha256"  -mtime +"$RETENTION_DAYS" -print -delete || true
}

# -------- Main --------
# Single-run lock
exec 9>/var/lock/backup-sites.lock
if ! flock -n 9; then
  log "Another backup run is in progress, exiting"
  exit 0
fi

umask "$UMASK_VALUE"
ensure_dir "$DEST_BASE" 750

# Iterate domains in /var/www
if [[ ! -d "$SITES_DIR" ]]; then
  log "No $SITES_DIR found. Nothing to back up."
  exit 0
fi

status=0
shopt -s nullglob
for path in "$SITES_DIR"/*; do
  [[ -d "$path" ]] || continue
  domain=$(basename "$path")
  # Skip hidden dirs just in case
  [[ "$domain" =~ ^\. ]] && continue

  if ! archive_site "$domain"; then
    status=1
  fi
done
shopt -u nullglob

exit "$status"
