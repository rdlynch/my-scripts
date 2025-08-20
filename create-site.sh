#!/bin/bash
# Create a new site (Grav or Hugo) on Debian 12 with Caddy + PHP-FPM
# Usage: create-site domain.com [grav|hugo]
# Example: create-site example.org grav
#
# Behavior:
# - Grav installs per-site under /var/www/<domain>
# - Hugo uses /var/www/<domain>/site (sources) and /var/www/<domain>/public (webroot)
# - Appends a site block to /etc/caddy/Caddyfile and reloads Caddy
# - Writes JSON access logs to /var/log/caddy/<domain>.log for Fail2ban
#
# Requirements:
# - Run as root
# - Caddy and PHP-FPM installed (server-setup.sh handles this)
# - Repo cloned to /opt/server-scripts

set -euo pipefail
trap 'echo "ERROR: create-site failed at line $LINENO" >&2' ERR

# ---- Config -------------------------------------------------------------------
SITES_DIR="/var/www"
CADDYFILE="/etc/caddy/Caddyfile"
PHP_SOCK="/run/php/php8.2-fpm.sock"
LOG_DIR="/var/log/caddy"
WWW_USER="www-data"
WWW_GROUP="www-data"

# Hugo on-demand install config
INSTALL_HUGO_ON_DEMAND="yes"
# Set a pinned version for reproducibility. Use "latest" to fetch latest at runtime.
HUGO_VERSION="${HUGO_VERSION:-0.126.1}"   # change as desired
ARCH="$(dpkg --print-architecture)"       # usually amd64 on Linode

# ---- Helpers ------------------------------------------------------------------
usage() {
  echo "Usage: $0 domain.com [grav|hugo]"
  echo "Example: $0 example.org grav"
  echo ""
  echo "Types:"
  echo "  grav  Grav CMS (no admin plugin by default)"
  echo "  hugo  Hugo static site (build on server; optional on-demand Hugo install)"
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
append_if_missing() { local f="$1" s="$2"; grep -Fqs "$s" "$f" || printf "%s\n" "$s" >> "$f"; }

install_hugo() {
  if command -v hugo >/dev/null 2>&1; then
    echo "Hugo already installed."
    return 0
  fi

  [[ "$INSTALL_HUGO_ON_DEMAND" == "yes" ]] || { echo "Hugo not installed and on-demand install disabled."; return 1; }

  local ver="$HUGO_VERSION"
  if [[ "$ver" == "latest" ]]; then
    # Fetch latest tag name from GitHub API
    ver="$(curl -fsSL https://api.github.com/repos/gohugoio/hugo/releases/latest | awk -F'"' '/tag_name/ {print $4}' | sed 's/^v//')"
    [[ -n "$ver" ]] || { echo "Failed to get latest Hugo version."; return 1; }
  fi

  echo "Installing Hugo Extended v${ver}..."
  local pkg="/tmp/hugo_extended_${ver}_linux-${ARCH}.deb"
  local url="https://github.com/gohugoio/hugo/releases/download/v${ver}/hugo_extended_${ver}_linux-${ARCH}.deb"

  curl -fsSL -o "$pkg" "$url"
  apt-get install -y "$pkg"
  rm -f "$pkg"
  echo "Hugo v${ver} installed."
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

harden_permissions() {
  local dir="$1"
  chown -R "$WWW_USER:$WWW_GROUP" "$dir"
  find "$dir" -type d -print0 | xargs -0 chmod 755
  find "$dir" -type f -print0 | xargs -0 chmod 644
}

# ---- Args ---------------------------------------------------------------------
require_root
DOMAIN="${1:-}"
TYPE="${2:-grav}"

[[ -n "$DOMAIN" ]] || usage
valid_domain "$DOMAIN" || { echo "Invalid domain: $DOMAIN" >&2; exit 1; }
[[ "$TYPE" == "grav" || "$TYPE" == "hugo" ]] || usage

SITEDIR="$SITES_DIR/$DOMAIN"
echo "Creating $TYPE site for $DOMAIN"
echo "Site directory: $SITEDIR"

if [[ -e "$SITEDIR" ]]; then
  echo "ERROR: $SITEDIR already exists. Aborting." >&2
  exit 1
fi

# ---- Prep ---------------------------------------------------------------------
ensure_dir "$LOG_DIR" 755
chown caddy:caddy "$LOG_DIR" || true
ensure_dir "$SITEDIR" 755

# ---- Install per type ---------------------------------------------------------
if [[ "$TYPE" == "grav" ]]; then
  # Install Grav (core, no admin plugin) into site root
  echo "Installing Grav..."
  pushd /tmp >/dev/null
  # URL alias 'latest' is maintained by Grav project
  curl -fsSL -o grav-core.zip https://getgrav.org/download/core/grav/latest
  unzip -q grav-core.zip
  # The zip typically extracts into a folder named 'grav'
  shopt -s dotglob
  mv grav/* "$SITEDIR"/
  shopt -u dotglob
  popd >/dev/null
  rm -f /tmp/grav-core.zip
  # Recommended writable dirs for Grav
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

elif [[ "$TYPE" == "hugo" ]]; then
  # Hugo site: sources in site/, published HTML in public/
  echo "Preparing Hugo site layout..."
  SRC="$SITEDIR/site"
  PUB="$SITEDIR/public"
  ensure_dir "$SRC" 755
  ensure_dir "$PUB" 755

  if ! command -v hugo >/dev/null 2>&1; then
    echo "Hugo not found."
    install_hugo
  fi

  echo "Bootstrapping Hugo project..."
  hugo new site "$SRC" --force >/dev/null

  # Minimal, accessible config. User can replace later.
  cat > "$SRC/hugo.toml" <<'EOH'
baseURL = "/"
languageCode = "en-us"
title = "New Hugo Site"
enableRobotsTXT = true

[outputs]
home = ["HTML", "RSS"]

[markup.goldmark.renderer]
unsafe = false
EOH

  # Starter content
  hugo new --source "$SRC" posts/welcome.md >/dev/null || true
  sed -i 's/draft: true/draft: false/' "$SRC/content/posts/welcome.md" || true

  echo "Building site..."
  hugo --minify --source "$SRC" --destination "$PUB"

  harden_permissions "$SITEDIR"

  # Caddy block for Hugo
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
fi

# ---- Ownership, reload, next steps -------------------------------------------
harden_permissions "$SITEDIR"
reload_caddy

echo ""
echo "Site created."
echo "Domain: $DOMAIN"
echo "Type: $TYPE"
if [[ "$TYPE" == "hugo" ]]; then
  echo "Hugo sources: $SITEDIR/site"
  echo "Web root:     $SITEDIR/public"
  echo "Rebuild cmd:  hugo --minify --source $SITEDIR/site --destination $SITEDIR/public"
else
  echo "Grav root:    $SITEDIR"
  echo "Edit content: $SITEDIR/user/pages"
fi
echo "Caddy logs:   $LOG_DIR/$DOMAIN.log (JSON)"
echo "Remember DNS: point $DOMAIN to this server."
