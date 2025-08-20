#!/bin/bash
# Create a new site on Debian 12 with Caddy + PHP-FPM
# Usage: create-site domain.com [grav|hugo]
# Example: create-site theruralgrantguy.com hugo
#
# Behavior (Option 1 only for Hugo):
# - hugo: creates /var/www/<domain>/public only. You build locally and upload artifacts.
# - grav: installs Grav per site into /var/www/<domain> and configures PHP-FPM.
# - Appends a site block to /etc/caddy/Caddyfile, validates, and reloads Caddy.
# - Writes JSON access logs per site to /var/log/caddy/<domain>.log.

set -euo pipefail
trap 'echo "ERROR: create-site failed at line $LINENO" >&2' ERR

# ---- Config -------------------------------------------------------------------
SITES_DIR="/var/www"
CADDYFILE="/etc/caddy/Caddyfile"
PHP_SOCK="/run/php/php8.2-fpm.sock"
LOG_DIR="/var/log/caddy"
WWW_USER="www-data"
WWW_GROUP="www-data"

# ---- Helpers ------------------------------------------------------------------
usage() {
  echo "Usage: $0 domain.com [grav|hugo]"
  echo "Default type is hugo."
  exit 1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]
}

ensure_dir() { install -d -m "$2" "$1"; }
harden_permissions() {
  local dir="$1"
  chown -R "$WWW_USER:$WWW_GROUP" "$dir"
  find "$dir" -type d -print0 | xargs -0 chmod 755
  find "$dir" -type f -print0 | xargs -0 chmod 644
}
reload_caddy() {
  if caddy validate --config "$CADDYFILE"; then
    systemctl reload caddy
    echo "Caddy reloaded."
  else
    echo "ERROR: Caddyfile validation failed. Check $CADDYFILE" >&2
    exit 1
  fi
}

# ---- Args ---------------------------------------------------------------------
require_root
DOMAIN="${1:-}"
TYPE="${2:-hugo}"

[[ -n "$DOMAIN" ]] || usage
valid_domain "$DOMAIN" || { echo "Invalid domain: $DOMAIN" >&2; exit 1; }
[[ "$TYPE" == "grav" || "$TYPE" == "hugo" ]] || usage

SITEDIR="$SITES_DIR/$DOMAIN"

if [[ -e "$SITEDIR" ]]; then
  echo "ERROR: $SITEDIR already exists. Aborting to avoid overwriting." >&2
  exit 1
fi

# Ensure log directory exists
ensure_dir "$LOG_DIR" 755
chown caddy:caddy "$LOG_DIR" || true

# ---- Site creation ------------------------------------------------------------
if [[ "$TYPE" == "hugo" ]]; then
  # Option 1 only: no Hugo install, no server build.
  PUB="$SITEDIR/public"
  ensure_dir "$PUB" 755

  # Minimal placeholder so the domain does not 404 before your first upload
  cat > "$PUB/index.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Site ready for deploy</title>
<p>This site is ready. Upload your built files into this folder.</p>
EOF

  harden_permissions "$SITEDIR"

  # Caddy block for static site
  cat >>"$CADDYFILE" <<EOF

$DOMAIN {
    root * $PUB
    encode gzip zstd
    file_server
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer-when-downgrade"
        X-Frame-Options "SAMEORIGIN"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
    }
    log {
        output file $LOG_DIR/$DOMAIN.log {
            roll_size 25MiB
            roll_keep 14
            roll_keep_for 336h
        }
        format json
    }
}
EOF

else
  # Grav per-site install
  ensure_dir "$SITEDIR" 755
  echo "Installing Grav into $SITEDIR ..."
  pushd /tmp >/dev/null
  curl -fsSL -o grav-core.zip https://getgrav.org/download/core/grav/latest
  unzip -q grav-core.zip
  shopt -s dotglob
  mv grav/* "$SITEDIR"/
  shopt -u dotglob
  popd >/dev/null
  rm -f /tmp/grav-core.zip

  # Writable dirs for Grav
  find "$SITEDIR"/{cache,images,assets,logs,backup} -type d 2>/dev/null | xargs -r chmod 775 || true
  harden_permissions "$SITEDIR"

  # Caddy block for Grav
  cat >>"$CADDYFILE" <<EOF

$DOMAIN {
    root * $SITEDIR
    encode gzip zstd
    try_files {path} {path}/ /index.php?{query}
    php_fastcgi unix//$PHP_SOCK
    file_server
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer-when-downgrade"
        X-Frame-Options "SAMEORIGIN"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
    }
    log {
        output file $LOG_DIR/$DOMAIN.log {
            roll_size 25MiB
            roll_keep 14
            roll_keep_for 336h
        }
        format json
    }
}
EOF
fi

reload_caddy

echo "Site created."
echo "Domain: $DOMAIN"
echo "Type: $TYPE"
if [[ "$TYPE" == "hugo" ]]; then
  echo "Upload your local build artifacts to: $SITEDIR/public"
  echo "On Windows: build with 'hugo --minify' then mirror 'public' via WinSCP."
else
  echo "Grav root: $SITEDIR"
  echo "Content lives in: $SITEDIR/user/pages"
fi
echo "Caddy logs: $LOG_DIR/$DOMAIN.log (JSON)"
