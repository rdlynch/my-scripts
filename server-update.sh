#!/bin/bash

echo "Updating server packages..."
apt update && apt upgrade -y && apt autoremove -y && apt autoclean

echo "Updating configuration files from GitHub..."
cd /root/my-scripts
git pull origin main

# Check if any config files were updated and apply them
if [ -f "jail.local" ]; then
    if ! cmp -s jail.local /etc/fail2ban/jail.local; then
        echo "Updating Fail2Ban configuration..."
        cp jail.local /etc/fail2ban/jail.local
        systemctl restart fail2ban
    fi
fi

if [ -f "caddy-auth.conf" ]; then
    if ! cmp -s caddy-auth.conf /etc/fail2ban/filter.d/caddy-auth.conf; then
        echo "Updating Fail2Ban Caddy filter..."
        cp caddy-auth.conf /etc/fail2ban/filter.d/caddy-auth.conf
        systemctl restart fail2ban
    fi
fi

if [ -f "logrotate-caddy-sites" ]; then
    if ! cmp -s logrotate-caddy-sites /etc/logrotate.d/caddy-sites; then
        echo "Updating log rotation configuration..."
        cp logrotate-caddy-sites /etc/logrotate.d/caddy-sites
    fi
fi

echo "Updating Hugo..."
HUGO_VERSION=$(curl -s https://api.github.com/repos/gohugoio/hugo/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
CURRENT_VERSION=$(hugo version 2>/dev/null | grep -o 'v[0-9.]*' | head -1 | sed 's/v//')

if [ "$HUGO_VERSION" != "$CURRENT_VERSION" ]; then
    echo "Updating Hugo from $CURRENT_VERSION to $HUGO_VERSION..."
    wget -O /tmp/hugo.deb "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.deb"
    dpkg -i /tmp/hugo.deb
    rm /tmp/hugo.deb
    echo "Hugo updated successfully"
else
    echo "Hugo is already up to date"
fi

echo "Restarting services..."
systemctl restart php8.2-fpm
systemctl reload caddy

echo "Server update completed"
