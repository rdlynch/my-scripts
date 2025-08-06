#!/bin/bash

# WordPress Clean Installation Script
# Usage: wp-clean domain.com

if [ $# -ne 1 ]; then
    echo "Usage: wp-clean domain.com"
    exit 1
fi

DOMAIN=$1
SITENAME=$(echo $DOMAIN | cut -d'.' -f1)
SITE_DIR="/var/www/$SITENAME"
DB_NAME=$(echo $DOMAIN | sed 's/\./_/g')
DB_USER=$(echo $DOMAIN | sed 's/\./_/g' | cut -c1-16)
DB_PASS=$(openssl rand -base64 12)

# Get admin credentials
read -p "WordPress admin username: " WP_ADMIN_USER
read -s -p "WordPress admin password: " WP_ADMIN_PASS
echo
read -p "WordPress admin email: " WP_ADMIN_EMAIL

echo "Creating WordPress site: $DOMAIN"

# Create directory structure
mkdir -p $SITE_DIR
cd $SITE_DIR

# Load secrets for API keys and licenses
echo "Loading API configuration..."
if [ -f /root/.wp-secrets ]; then
    source /root/.wp-secrets
    if [ -z "$POSTMARK_TOKEN" ] || [ -z "$WPVIVID_KEY" ]; then
        echo "Warning: Missing API keys in /root/.wp-secrets"
        echo "Some plugin configurations may be incomplete"
    fi
else
    echo "Warning: /root/.wp-secrets not found"
    echo "Plugin auto-configuration will be skipped"
fi

# Create database
echo "Creating database..."
mysql -u root -p << MYSQL_SCRIPT
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Download and configure WordPress
echo "Downloading WordPress..."
wp core download --allow-root
wp core config --dbname=$DB_NAME --dbuser=$DB_USER --dbpass=$DB_PASS --allow-root

# Remove default WordPress files
echo "Cleaning default WordPress files..."
rm -f readme.html license.txt

# Add security configurations to wp-config.php
wp config set WP_POST_REVISIONS 3 --allow-root
wp config set DISALLOW_FILE_EDIT true --allow-root
wp config set WP_AUTO_UPDATE_CORE minor --allow-root
wp config set DISABLE_WP_CRON true --allow-root

# Install WordPress
echo "Installing WordPress..."
wp core install --url=$DOMAIN --title="$DOMAIN" --admin_user=$WP_ADMIN_USER --admin_password=$WP_ADMIN_PASS --admin_email=$WP_ADMIN_EMAIL --allow-root

# Configure basic WordPress settings
echo "Configuring WordPress settings..."
wp option update timezone_string 'America/Chicago' --allow-root
wp rewrite structure '/%postname%/' --allow-root
wp option update posts_per_page 5 --allow-root

# Disable comments globally
wp option update default_comment_status 'closed' --allow-root
wp option update default_ping_status 'closed' --allow-root

# Remove default content
echo "Cleaning default content..."
wp post delete 1 2 3 --force --allow-root  # Default post, page, and privacy policy
wp comment delete 1 --force --allow-root   # Default comment

# Install and activate themes
echo "Installing themes..."
wp theme install generatepress --activate --allow-root
wp theme install twentytwentyfive --allow-root

# Install and activate required plugins
echo "Installing and activating plugins..."
wp plugin install fluent-smtp --activate --allow-root
wp plugin install fluentform --activate --allow-root
wp plugin install classic-editor --activate --allow-root
wp plugin install tinymce-advanced --activate --allow-root
wp plugin install limit-login-attempts-reloaded --activate --allow-root

# Install but don't activate
wp plugin install seo-by-rank-math --allow-root

# Configure FluentSMTP for Postmark
if [ ! -z "$POSTMARK_TOKEN" ]; then
    echo "Configuring FluentSMTP for Postmark..."
    
    # Get site name for sender name
    SITE_NAME=$(wp option get blogname --allow-root)
    FROM_EMAIL="wordpress@${DOMAIN}"
    
    wp option update fluentmail_settings "{
        \"connections\": {
            \"postmark\": {
                \"provider\": \"postmark\",
                \"sender_name\": \"${SITE_NAME}\",
                \"sender_email\": \"${FROM_EMAIL}\",
                \"server_token\": \"${POSTMARK_TOKEN}\",
                \"force_from_name\": \"yes\",
                \"force_from_email\": \"yes\"
            }
        },
        \"misc\": {
            \"default_connection\": \"postmark\"
        }
    }" --format=json --allow-root
    
    echo "FluentSMTP configured with ${FROM_EMAIL}"
else
    echo "Skipping FluentSMTP configuration - POSTMARK_TOKEN not found"
fi

# Install and configure premium plugins
echo "Installing premium plugins..."
if [ -d "/opt/server-configs/premium-plugins" ]; then
    for plugin_zip in /opt/server-configs/premium-plugins/*.zip; do
        if [ -f "$plugin_zip" ]; then
            plugin_name=$(basename "$plugin_zip" .zip)
            echo "Installing ${plugin_name}..."
            wp plugin install "$plugin_zip" --activate --allow-root
            
            # Configure specific premium plugins
            case "$plugin_name" in
                "wpvivid"*)
                    if [ ! -z "$WPVIVID_KEY" ]; then
                        echo "Configuring WPvivid license..."
                        wp option update wpvivid_license_key "$WPVIVID_KEY" --allow-root
                        echo "WPvivid license key configured"
                    fi
                    ;;
            esac
        fi
    done
else
    echo "No premium plugins directory found, skipping..."
fi

# Create custom pages
echo "Creating pages..."
wp post create --post_type=page --post_title="Home" --post_status=publish --allow-root
wp post create --post_type=page --post_title="About" --post_status=publish --allow-root
wp post create --post_type=page --post_title="Blog" --post_status=publish --allow-root
wp post create --post_type=page --post_title="Privacy Policy" --post_status=publish --allow-root

# Set front page and posts page
HOME_ID=$(wp post list --post_type=page --name=home --field=ID --allow-root)
BLOG_ID=$(wp post list --post_type=page --name=blog --field=ID --allow-root)

wp option update show_on_front 'page' --allow-root
wp option update page_on_front $HOME_ID --allow-root
wp option update page_for_posts $BLOG_ID --allow-root

# Set proper ownership
chown -R www-data:www-data $SITE_DIR
chmod -R 755 $SITE_DIR

# Create Nginx vhost
echo "Creating Nginx configuration..."
cat > /etc/nginx/sites-available/$DOMAIN << NGINX_CONF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root $SITE_DIR;
    index index.php index.html;

    # Include 8G Firewall
    include /etc/nginx/8g-firewall.conf;

    # WordPress permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # PHP processing
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Deny access to sensitive files
    location ~ /\. {
        deny all;
    }
    
    location ~* /(?:uploads|files)/.*\.php\$ {
        deny all;
    }

    # Cache static files
    location ~* \.(jpg|jpeg|gif|png|css|js|ico|xml)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # WordPress security
    location = /wp-config.php { deny all; }
    location = /readme.html { deny all; }
    location = /license.txt { deny all; }
}
NGINX_CONF

# Enable site
ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# Install SSL certificate
echo "Installing SSL certificate..."
certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email $WP_ADMIN_EMAIL --redirect

echo ""
echo "========================================="
echo "Site created successfully!"
echo "========================================="
echo "Domain: $DOMAIN"
echo "Directory: $SITE_DIR"
echo "Database: $DB_NAME"
echo "DB User: $DB_USER"
echo "DB Password: $DB_PASS"
echo "Admin User: $WP_ADMIN_USER"
echo "Admin Password: $WP_ADMIN_PASS"
echo "========================================="
echo "SSL Certificate: Installed"
echo "Site URL: https://$DOMAIN"
echo "Admin URL: https://$DOMAIN/wp-admin"
echo "========================================="
echo "Your site is ready to use!"
echo "========================================="
