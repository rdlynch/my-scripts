#!/bin/bash

# Git-based server tools including your personal configs
declare -A git_tools=(
    ["/opt/nG-SetEnvIf"]="https://github.com/t18d/nG-SetEnvIf.git"
    ["/opt/server-configs"]="https://github.com/myuser/my-scripts.git"
)

for tool_path in "${!git_tools[@]}"; do
    if [ -d "$tool_path" ]; then
        echo "Updating $(basename $tool_path)..."
        cd "$tool_path"
        git pull origin main
        
        # If server-configs updated, copy files to their locations
        if [[ "$tool_path" == "/opt/server-configs" ]]; then
            echo "Updating server configuration files..."
            cp /opt/server-configs/wp-clean-install.sh /root/
            cp /opt/server-configs/wp-cron-runner.sh /root/
            cp /opt/server-configs/server-update.sh /root/
            chmod +x /root/wp-clean-install.sh /root/wp-cron-runner.sh /root/server-update.sh
            
            # Update system configs if they changed
            cp /opt/server-configs/jail.local /etc/fail2ban/jail.local
            cp /opt/server-configs/logrotate-nginx-wordpress /etc/logrotate.d/nginx-wordpress
            
            systemctl restart fail2ban
            echo "Server configuration files updated"
        fi
    else
        echo "Cloning $(basename $tool_path)..."
        git clone "${git_tools[$tool_path]}" "$tool_path"
    fi
done

# Test Nginx config after firewall updates
nginx -t && systemctl reload nginx
echo "Git tools updated: $(date)" >> /var/log/maintenance.log
