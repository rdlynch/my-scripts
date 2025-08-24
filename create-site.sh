#!/bin/bash
# Create a new site on Debian 12 with Caddy + PHP-FPM
# Usage: create-site domain.com [grav|hugo]
#
# Behavior (Option 1 only for Hugo):
# - hugo: creates /var/www/<domain>/public only. You build locally and upload artifacts.
# - grav: installs Grav per site into /var/www/<domain> and configures PHP-FPM.
# - Appends a site block to /etc/caddy/Caddyfile, validates, and reloads Caddy.
# - Writes JSON access logs per site to /var/log/caddy/<domain>.log.

set -euo pipefail
trap 'echo "ERROR: create-site failed at line $LINENO" >&2' ERR

SITES_DIR="/var/www"
CADDYFILE="/etc/caddy/Caddyfile"
PHP_SOCK="/run/php/php8.2-fpm.sock"
LOG_DIR="/var/log/caddy"
WWW_USER="www-data"
WWW_GROUP="www-data"

usage() { echo "Usage: $0 domain.com [grav|hugo]"; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || { echo "Please run as root." >&2; exit 1; }; }
valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; }
ensure_dir() { install -d -m "$2" "$1"; }
harden_permissions() {
  chown -R "$WWW_USER:$WWW_GROUP" "$1"
  find "$1" -type d -print0 | xargs -0 chmod 755
  find "$1" -type f -print0 | xargs -0 chmod 644
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

require_root
DOMAIN="${1:-}"; TYPE="${2:-hugo}"
[[ -n "$DOMAIN" ]] || usage
valid_domain "$DOMAIN" || { echo "Invalid domain: $DOMAIN" >&2; exit 1; }
[[ "$TYPE" == "grav" || "$TYPE" == "hugo" ]] || usage

SITEDIR="$SITES_DIR/$DOMAIN"
[[ -e "$SITEDIR" ]] && { echo "ERROR: $SITEDIR exists, aborting."; exit 1; }

ensure_dir "$LOG_DIR" 755
chown caddy:caddy "$LOG_DIR" || true

if [[ "$TYPE" == "hugo" ]]; then
  PUB="$SITEDIR/public"
  ensure_dir "$PUB" 755
  cat > "$PUB/index.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Site ready for deploy</title>
<p>This site is ready. Upload your built files into this folder.</p>
EOF
  harden_permissions "$SITEDIR"

  # Static site with a narrow PHP hook for the centralized form handler
  cat >>"$CADDYFILE" <<EOF

$DOMAIN, www.$DOMAIN {
    root * $PUB
    encode gzip zstd

    @form path /form-handler.php
    handle @form {
        root * /var/www
        php_fastcgi unix://$PHP_SOCK
    }

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

  find "$SITEDIR"/{cache,images,assets,logs,backup} -type d 2>/dev/null | xargs -r chmod 775 || true
  harden_permissions "$SITEDIR"

  # Full PHP site plus the same centralized form handler path
  cat >>"$CADDYFILE" <<EOF

$DOMAIN, www.$DOMAIN {
    root * $SITEDIR
    encode gzip zstd

    @form path /form-handler.php
    handle @form {
        root * /var/www
        php_fastcgi unix://$PHP_SOCK
    }

    try_files {path} {path}/ /index.php?{query}
    php_fastcgi unix://$PHP_SOCK
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
echo "Upload Hugo builds to: $SITEDIR/public"
echo "Grav root (if used):   $SITEDIR"
echo "Caddy logs:            $LOG_DIR/$DOMAIN.log (JSON)"
