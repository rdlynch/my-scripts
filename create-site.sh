#!/bin/bash

# Create new site (Grav or Hugo) for Alpha Omega Strategies
# Usage: create-site.sh domain.com [grav|hugo]
# Example: create-site.sh mysite.com grav

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 domain.com [grav|hugo]"
    echo "Example: $0 mysite.com grav"
    echo ""
    echo "Available types:"
    echo "  grav  - Grav CMS with Hadron theme (no admin panel)"
    echo "  hugo  - Hugo static site with Clarity theme"
    exit 1
fi

DOMAIN=$1
TYPE=${2:-grav}
SITENAME=$(echo $DOMAIN | sed 's/\..*//')
SITEDIR="/var/www/$SITENAME"

# Validate inputs
if [ -d "$SITEDIR" ]; then
    echo "Error: Site directory $SITEDIR already exists"
    echo "Remove it first or choose a different domain name"
    exit 1
fi

if [[ ! "$TYPE" =~ ^(grav|hugo)$ ]]; then
    echo "Error: Unknown site type '$TYPE'. Use 'grav' or 'hugo'"
    exit 1
fi

# Cleanup function for failed installations
cleanup_failed_site() {
    echo "Cleaning up failed installation..."
    
    # Remove site directory if it exists
    if [ -d "$SITEDIR" ]; then
        rm -rf "$SITEDIR"
        echo "Removed site directory: $SITEDIR"
    fi
    
    # Remove Caddy configuration block if it was added
    if grep -q "# $DOMAIN" /etc/caddy/Caddyfile 2>/dev/null; then
        echo "Removing Caddy configuration..."
        head -n -$(($(grep -n "# $DOMAIN" /etc/caddy/Caddyfile | tail -1 | cut -d: -f1) - 1)) /etc/caddy/Caddyfile > /tmp/caddyfile.tmp
        mv /tmp/caddyfile.tmp /etc/caddy/Caddyfile
    fi
    
    # Clean up temporary files
    cd /tmp
    rm -f grav-core.zip
    rm -rf grav
    
    echo "Cleanup completed"
    exit 1
}

# Set trap to run cleanup on script failure
trap cleanup_failed_site ERR

echo "Creating $TYPE site for $DOMAIN..."
echo "Site directory: $SITEDIR"

if [ "$TYPE" = "grav" ]; then
    echo "Installing fresh Grav CMS..."
    
    # Download and install Grav directly
    cd /tmp
    if ! wget https://getgrav.org/download/core/grav/latest -O grav-core.zip; then
        echo "ERROR: Failed to download Grav"
        exit 1
    fi
    
    if ! unzip -q grav-core.zip; then
        echo "ERROR: Failed to extract Grav archive"
        rm -f grav-core.zip
        exit 1
    fi
    
    if ! mv grav "$SITEDIR"; then
        echo "ERROR: Failed to move Grav to site directory"
        rm -rf grav grav-core.zip
        exit 1
    fi
    
    rm grav-core.zip
    echo "SUCCESS: Grav core installed"
    
    # Set proper permissions 
    chown -R www-data:www-data "$SITEDIR"
    chmod -R 755 "$SITEDIR"
    chmod -R 775 "$SITEDIR"/{cache,logs,tmp,backup,user}
    echo "SUCCESS: Permissions set"
    
    # Install Hadron theme
    echo "Installing Hadron theme..."
    cd "$SITEDIR"
    if ! sudo -u www-data php bin/gpm install hadron -y; then
        echo "ERROR: Failed to install Hadron theme"
        exit 1
    fi
    
    # Set Hadron as the default theme
    if ! sudo -u www-data sed -i "s/theme: .*/theme: hadron/" user/config/system.yaml; then
        echo "ERROR: Failed to set Hadron as default theme"
        exit 1
    fi
    echo "SUCCESS: Hadron theme installed and activated"
    
    # Create site configuration
    echo "Creating site configuration..."
    cat > "$SITEDIR/user/config/site.yaml" << EOL
title: '$DOMAIN'
author:
  name: 'Alpha Omega Strategies'
  email: 'admin@$DOMAIN'
metadata:
  description: 'Professional consulting services'
  keywords: 'consulting, rural development, grants, strategic planning'
taxonomies: [category,tag]
summary:
  enabled: true
  format: short
  size: 300
blog:
  route: '/blog'
accessibility:
  enabled: true
  skip_links: true
  high_contrast: false
cache:
  enabled: true
  check:
    method: file
twig:
  cache: true
  debug: false
  auto_reload: false
debugger:
  enabled: false
  shutdown:
    close_connection: true
EOL
    echo "SUCCESS: Site configuration created"

    # Add site configuration to Caddyfile
    echo "Adding Caddy configuration..."
    cat >> /etc/caddy/Caddyfile << EOL

# $DOMAIN - Grav CMS Site with Hadron Theme
$DOMAIN {
    root * $SITEDIR
    php_fastcgi unix//run/php/php8.2-fpm.sock
    file_server
    
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
    
    # Grav-specific security rules
    @forbidden {
        path /*.md /*.txt /*.yaml /*.yml /*.php~ /*.orig /*.bak
        path /cache/* /logs/* /tmp/* /backup/* /system/* /vendor/*
        path /.git/* /.gitignore /.htaccess
    }
    respond @forbidden 403
    
    # Enable compression
    encode gzip
    
    # Cache static assets
    @static {
        path *.css *.js *.png *.jpg *.jpeg *.gif *.svg *.woff *.woff2 *.ico
    }
    header @static Cache-Control "public, max-age=31536000"    
}
EOL

    echo "Grav site with Hadron theme created successfully!"
    echo "Edit content in: $SITEDIR/user/pages/"
    echo "Form handler available at: https://$DOMAIN/form-handler.php"

elif [ "$TYPE" = "hugo" ]; then
    echo "Creating fresh Hugo site..."
    
    # Create new Hugo site
    if ! hugo new site "$SITEDIR"; then
        echo "ERROR: Failed to create Hugo site"
        exit 1
    fi
    
    cd "$SITEDIR"
    echo "SUCCESS: Hugo site structure created"
    
    # Install Clarity theme
    echo "Installing Clarity theme..."
    if ! git init; then
        echo "ERROR: Failed to initialize git repository"
        exit 1
    fi
    
    if ! git submodule add https://github.com/chipzoller/hugo-clarity themes/clarity; then
        echo "ERROR: Failed to install Clarity theme"
        exit 1
    fi
    
    # Copy example config if it exists
    if [ -d "themes/clarity/exampleSite/config" ]; then
        cp -r themes/clarity/exampleSite/config/* config/ 2>/dev/null || true
        echo "SUCCESS: Copied example configuration"
    fi
    
    # Set proper permissions
    chown -R www-data:www-data "$SITEDIR"
    chmod -R 755 "$SITEDIR"
    echo "SUCCESS: Permissions set"
    
    # Update config for this domain
    echo "Configuring site for $DOMAIN..."
    sed -i "s|baseURL = .*|baseURL = 'https://$DOMAIN'|" config/_default/config.yaml 2>/dev/null || true
    sed -i "s|title = .*|title = '$DOMAIN'|" config/_default/config.yaml 2>/dev/null || true
    
    # Build the site
    echo "Building Hugo site..."
    if ! hugo --minify; then
        echo "ERROR: Failed to build Hugo site"
        exit 1
    fi
    echo "SUCCESS: Hugo site built"
    
    # Add site configuration to Caddyfile
    echo "Adding Caddy configuration..."
    cat >> /etc/caddy/Caddyfile << EOL

# $DOMAIN - Hugo Static Site with Clarity Theme
$DOMAIN {
    root * $SITEDIR/public
    file_server
    
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
    
    # Enable compression
    encode gzip
    
    # Cache static assets aggressively
    @static {
        path *.css *.js *.png *.jpg *.jpeg *.gif *.svg *.woff *.woff2 *.ico *.pdf
    }
    header @static Cache-Control "public, max-age=31536000, immutable"
    
    # Cache HTML for shorter time
    @html {
        path *.html /
    }
    header @html Cache-Control "public, max-age=300"
    
    # Handle clean URLs (remove .html extension)
    try_files {path} {path}.html {path}/ =404
}
EOL

    echo "Hugo site with Clarity theme created successfully!"
    echo "Edit content in: $SITEDIR/content/"
    echo "Rebuild with: cd $SITEDIR && hugo --minify"
    echo "Form handler available at: https://$DOMAIN/form-handler.php"
fi

# Test Caddy configuration
echo "Testing Caddy configuration..."
if caddy validate --config /etc/caddy/Caddyfile; then
    echo "Configuration valid. Reloading Caddy..."
    caddy reload --config /etc/caddy/Caddyfile
else
    echo "ERROR: Caddy configuration is invalid!"
    echo "Removing the added configuration..."
    # Remove the last site block we just added
    head -n -$(($(grep -n "# $DOMAIN" /etc/caddy/Caddyfile | tail -1 | cut -d: -f1) - 1)) /etc/caddy/Caddyfile > /tmp/caddyfile.tmp
    mv /tmp/caddyfile.tmp /etc/caddy/Caddyfile
    exit 1
fi

# Clear the trap since we succeeded
trap - ERR

echo ""
echo "========================================="
echo "Site created successfully!"
echo "========================================="
echo "Domain: $DOMAIN"
echo "Type: $TYPE"
echo "Directory: $SITEDIR"
if [ "$TYPE" = "grav" ]; then
    echo "Theme: Hadron"
else
    echo "Theme: Clarity"
fi
echo ""
echo "Next steps:"
echo "1. Update DNS to point $DOMAIN to this server"
echo "2. SSL certificate will be automatically generated by Caddy"
if [ "$TYPE" = "grav" ]; then
    echo "3. Edit content in $SITEDIR/user/pages/"
    echo "4. Customize theme in $SITEDIR/user/config/"
else
    echo "3. Edit content in $SITEDIR/content/"
    echo "4. Rebuild site with: cd $SITEDIR && hugo --minify"
fi
echo "5. Form handler available at: https://$DOMAIN/form-handler.php"
echo "========================================="
