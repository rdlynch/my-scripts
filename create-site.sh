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

echo "Creating $TYPE site for $DOMAIN..."
echo "Site directory: $SITEDIR"

if [ "$TYPE" = "grav" ]; then
    # Copy Grav template
    echo "Copying Grav template with Hadron theme..."
    cp -r /opt/templates/grav-template "$SITEDIR"
    
    # Set proper permissions 
    chown -R www-data:www-data "$SITEDIR"
    chmod -R 755 "$SITEDIR"
    chmod -R 775 "$SITEDIR"/{cache,logs,tmp,backup,user}
    
    # Install Hadron theme
    cd "$SITEDIR"
    sudo -u www-data php bin/gpm install hadron -y
    
    # Set Hadron as the default theme
    sudo -u www-data sed -i "s/theme: .*/theme: hadron/" user/config/system.yaml
    
    # Clear any existing cache/logs
    rm -rf "$SITEDIR"/{cache,logs,tmp,backup}/*
    
    # Create basic site configuration for Hadron
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
debugger:
  enabled: false
  shutdown:
    close_connection: true
EOL

    # Add site configuration to Caddyfile
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
    echo "Admin panel will be available at: https://$DOMAIN/admin"
    echo "Configure the admin user on first visit"

elif [ "$TYPE" = "hugo" ]; then
    # Copy Hugo template
    echo "Copying Hugo template with Clarity theme..."
    cp -r /opt/templates/hugo-template "$SITEDIR"
    
    # Set proper permissions
    chown -R www-data:www-data "$SITEDIR"
    chmod -R 755 "$SITEDIR"
    
    # Update config for this domain
    cd "$SITEDIR"
    sed -i "s|baseURL = .*|baseURL = 'https://$DOMAIN'|" config/_default/config.yaml
    sed -i "s|title = .*|title = '$DOMAIN'|" config/_default/config.yaml
    
    # Build the site
    echo "Building Hugo site..."
    hugo --minify
    
    # Add site configuration to Caddyfile
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
fi

# Test Caddy configuration
echo "Testing Caddy configuration..."
if caddy validate --config /etc/caddy/Caddyfile; then
    echo "Configuration valid. Reloading Caddy..."
    caddy reload --config /etc/caddy/Caddyfile
else
    echo "Error: Caddy configuration is invalid!"
    echo "Removing the added configuration..."
    # Remove the last site block we just added
    head -n -$(($(grep -n "# $DOMAIN" /etc/caddy/Caddyfile | tail -1 | cut -d: -f1) - 1)) /etc/caddy/Caddyfile > /tmp/caddyfile.tmp
    mv /tmp/caddyfile.tmp /etc/caddy/Caddyfile
    exit 1
fi

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
    echo "3. Visit https://$DOMAIN/admin to set up Grav admin user"
    echo "4. Customize Hadron theme settings in admin panel"
else
    echo "3. Edit content in $SITEDIR/content/"
    echo "4. Rebuild site with: cd $SITEDIR && hugo --minify"
fi
echo "5. Form handler available at: https://$DOMAIN/form-handler.php"
echo "========================================="
