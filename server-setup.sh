#!/bin/bash

# Automated Debian 12 Server Setup
# Caddy + Grav CMS + Hugo + PHP Form Handler
# For Alpha Omega Strategies

set -e  # Exit on any error

echo "Starting Debian 12 server setup for Alpha Omega Strategies..."

# Update the server
echo "Updating system packages..."
apt update && apt upgrade -y && apt autoremove -y && apt autoclean

# Set timezone
echo "Setting timezone to America/Chicago..."
timedatectl set-timezone America/Chicago

# Create swap file (8GB for 4GB RAM system)
echo "Creating 8GB swap file..."
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Configure UFW Firewall
echo "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Install essential packages
echo "Installing essential packages..."
apt install -y curl wget git unzip htop fail2ban logrotate cron \
    software-properties-common apt-transport-https ca-certificates \
    gnupg lsb-release

# Clone server configuration files from GitHub
echo "Downloading server configuration files from GitHub..."
cd /opt
git clone https://github.com/rdlynch/my-scripts.git server-configs

# Install and configure Fail2Ban
echo "Configuring Fail2Ban..."
systemctl enable fail2ban
systemctl start fail2ban

# Use jail.local from your GitHub repo
cp /opt/server-configs/jail.local /etc/fail2ban/jail.local

# Use Caddy auth filter from your GitHub repo  
cp /opt/server-configs/caddy-auth.conf /etc/fail2ban/filter.d/caddy-auth.conf

systemctl restart fail2ban

# Install Caddy
echo "Installing Caddy web server..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy -y

# Enable and start Caddy
systemctl enable caddy
systemctl start caddy

# Install PHP 8.2 and required modules
echo "Installing PHP 8.2 and modules..."
apt install -y php8.2-fpm php8.2-cli php8.2-curl php8.2-gd php8.2-mbstring \
    php8.2-xml php8.2-zip php8.2-intl php8.2-bcmath php8.2-yaml \
    php8.2-json php8.2-opcache php8.2-readline

# Configure PHP for better performance and security
echo "Configuring PHP..."
sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 5M/' /etc/php/8.2/fpm/php.ini
sed -i 's/post_max_size = 8M/post_max_size = 6M/' /etc/php/8.2/fpm/php.ini
sed -i 's/memory_limit = 128M/memory_limit = 256M/' /etc/php/8.2/fpm/php.ini
sed -i 's/max_execution_time = 30/max_execution_time = 300/' /etc/php/8.2/fpm/php.ini
sed -i 's/max_input_vars = 1000/max_input_vars = 3000/' /etc/php/8.2/fpm/php.ini
sed -i 's/;opcache.enable=1/opcache.enable=1/' /etc/php/8.2/fpm/php.ini
sed -i 's/;opcache.memory_consumption=128/opcache.memory_consumption=128/' /etc/php/8.2/fpm/php.ini

# Enable and restart PHP-FPM
systemctl enable php8.2-fpm
systemctl restart php8.2-fpm

# Install Hugo
echo "Installing Hugo..."
HUGO_VERSION=$(curl -s https://api.github.com/repos/gohugoio/hugo/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
wget -O /tmp/hugo.deb "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.deb"
dpkg -i /tmp/hugo.deb
rm /tmp/hugo.deb

# Create directory structure
echo "Creating directory structure..."
mkdir -p /var/www
mkdir -p /var/backups/sites
mkdir -p /var/backups/server
mkdir -p /var/log/forms
mkdir -p /opt/templates

# Download and setup Grav CMS
echo "Installing Grav CMS..."
cd /tmp
wget https://getgrav.org/download/core/grav-admin/latest -O grav-admin.zip
unzip grav-admin.zip
mv grav-admin /var/www/cms
chown -R www-data:www-data /var/www/cms
chmod -R 755 /var/www/cms

# Install Grav plugins
echo "Installing Grav plugins..."
cd /var/www/cms
sudo -u www-data php bin/gpm install admin -y
sudo -u www-data php bin/gpm install form -y
sudo -u www-data php bin/gpm install email -y
sudo -u www-data php bin/gpm install postmark -y
sudo -u www-data php bin/gpm install table-importer -y
sudo -u www-data php bin/gpm install cloudflare-manager -y

# Create Hugo template site with Clarity theme
echo "Setting up Hugo template..."
cd /opt/templates
hugo new site hugo-template
cd hugo-template
git init
git submodule add https://github.com/chipzoller/hugo-clarity themes/clarity
cp themes/clarity/exampleSite/config/_default/* config/_default/ 2>/dev/null || true
hugo

# Create Grav template
echo "Creating Grav template..."
cp -r /var/www/cms /opt/templates/grav-template
cd /opt/templates/grav-template
rm -rf logs/* cache/* tmp/* backup/*

# Create PHP Form Handler
echo "Creating PHP form handler..."
cat > /var/www/form-handler.php << 'EOF'
<?php
/**
 * Universal Form Handler for Alpha Omega Strategies
 * Handles forms with Postmark email and Backblaze B2 logging
 * WCAG 2.2 AA Compliant
 */

// Error reporting for development (disable in production)
error_reporting(E_ALL);
ini_set('display_errors', 1);

// Security headers
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('X-XSS-Protection: 1; mode=block');

// Configuration
$config = [
    'postmark_token' => '', // Set your Postmark API token
    'b2_key_id' => '',      // Set your B2 Key ID
    'b2_app_key' => '',     // Set your B2 Application Key
    'b2_bucket' => '',      // Set your B2 bucket name
    'b2_endpoint' => '',    // Set your B2 endpoint URL
    'max_file_size' => 5 * 1024 * 1024, // 5MB
    'allowed_types' => ['pdf', 'doc', 'docx', 'txt', 'jpg', 'jpeg', 'png'],
    'log_dir' => '/var/log/forms'
];

// Load configuration from secure file
if (file_exists('/root/.form-secrets')) {
    $secrets = parse_ini_file('/root/.form-secrets');
    $config = array_merge($config, $secrets);
}

/**
 * Sanitize input data
 */
function sanitizeInput($data) {
    return htmlspecialchars(strip_tags(trim($data)), ENT_QUOTES, 'UTF-8');
}

/**
 * Validate email address
 */
function isValidEmail($email) {
    return filter_var($email, FILTER_VALIDATE_EMAIL) !== false;
}

/**
 * Log form submission
 */
function logSubmission($site, $data, $files = []) {
    global $config;
    
    $date = date('Y-m-d');
    $timestamp = date('Y-m-d H:i:s');
    $logDir = $config['log_dir'] . '/' . $site;
    
    if (!is_dir($logDir)) {
        mkdir($logDir, 0755, true);
    }
    
    $logFile = $logDir . '/' . $date . '.log';
    $logEntry = [
        'timestamp' => $timestamp,
        'ip' => $_SERVER['REMOTE_ADDR'] ?? 'unknown',
        'user_agent' => $_SERVER['HTTP_USER_AGENT'] ?? 'unknown',
        'form_data' => $data,
        'files' => $files
    ];
    
    file_put_contents($logFile, json_encode($logEntry) . "\n", FILE_APPEND | LOCK_EX);
}

/**
 * Upload file to Backblaze B2
 */
function uploadToB2($filePath, $fileName, $site) {
    global $config;
    
    if (empty($config['b2_key_id']) || empty($config['b2_app_key'])) {
        return false;
    }
    
    $date = date('Y-m-d');
    $b2Path = $site . '/' . $date . '/' . $fileName;
    
    // Simple B2 upload implementation
    // In production, consider using a proper B2 SDK
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL => $config['b2_endpoint'] . '/' . $config['b2_bucket'] . '/' . $b2Path,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => file_get_contents($filePath),
        CURLOPT_HTTPHEADER => [
            'Authorization: Basic ' . base64_encode($config['b2_key_id'] . ':' . $config['b2_app_key']),
            'Content-Type: application/octet-stream'
        ]
    ]);
    
    $result = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    return $httpCode === 200;
}

/**
 * Send email via Postmark
 */
function sendPostmarkEmail($to, $subject, $htmlBody, $textBody, $attachments = []) {
    global $config;
    
    if (empty($config['postmark_token'])) {
        return false;
    }
    
    $data = [
        'From' => 'noreply@' . $_SERVER['HTTP_HOST'],
        'To' => $to,
        'Subject' => $subject,
        'HtmlBody' => $htmlBody,
        'TextBody' => $textBody,
        'MessageStream' => 'outbound'
    ];
    
    if (!empty($attachments)) {
        $data['Attachments'] = $attachments;
    }
    
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL => 'https://api.postmarkapp.com/email',
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => json_encode($data),
        CURLOPT_HTTPHEADER => [
            'Accept: application/json',
            'Content-Type: application/json',
            'X-Postmark-Server-Token: ' . $config['postmark_token']
        ]
    ]);
    
    $result = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    return $httpCode === 200;
}

// Main form processing
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $response = ['success' => false, 'message' => ''];
    
    try {
        // Get site name from referrer or form data
        $site = sanitizeInput($_POST['site'] ?? parse_url($_SERVER['HTTP_REFERER'] ?? '', PHP_URL_HOST) ?? 'unknown');
        
        // Validate required fields
        if (empty($_POST['email']) || !isValidEmail($_POST['email'])) {
            throw new Exception('Valid email address is required.');
        }
        
        // Sanitize form data
        $formData = [];
        foreach ($_POST as $key => $value) {
            if ($key !== 'site') {
                $formData[$key] = sanitizeInput($value);
            }
        }
        
        // Handle file uploads
        $uploadedFiles = [];
        if (!empty($_FILES)) {
            foreach ($_FILES as $fieldName => $file) {
                if ($file['error'] === UPLOAD_ERR_OK) {
                    // Validate file
                    if ($file['size'] > $config['max_file_size']) {
                        throw new Exception('File size exceeds 5MB limit.');
                    }
                    
                    $extension = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
                    if (!in_array($extension, $config['allowed_types'])) {
                        throw new Exception('File type not allowed.');
                    }
                    
                    // Generate secure filename
                    $fileName = date('Y-m-d_H-i-s') . '_' . bin2hex(random_bytes(8)) . '.' . $extension;
                    $tempPath = $file['tmp_name'];
                    
                    // Upload to B2
                    if (uploadToB2($tempPath, $fileName, $site)) {
                        $uploadedFiles[] = [
                            'original_name' => $file['name'],
                            'stored_name' => $fileName,
                            'size' => $file['size']
                        ];
                    }
                }
            }
        }
        
        // Log the submission
        logSubmission($site, $formData, $uploadedFiles);
        
        // Prepare email content
        $subject = 'New Form Submission from ' . $site;
        $htmlBody = '<h2>New Form Submission</h2>';
        $textBody = "New Form Submission\n\n";
        
        foreach ($formData as $key => $value) {
            $label = ucwords(str_replace(['_', '-'], ' ', $key));
            $htmlBody .= '<p><strong>' . $label . ':</strong> ' . htmlspecialchars($value) . '</p>';
            $textBody .= $label . ': ' . $value . "\n";
        }
        
        if (!empty($uploadedFiles)) {
            $htmlBody .= '<h3>Uploaded Files:</h3><ul>';
            $textBody .= "\nUploaded Files:\n";
            
            foreach ($uploadedFiles as $file) {
                $htmlBody .= '<li>' . htmlspecialchars($file['original_name']) . ' (' . number_format($file['size'] / 1024, 2) . ' KB)</li>';
                $textBody .= '- ' . $file['original_name'] . ' (' . number_format($file['size'] / 1024, 2) . ' KB)' . "\n";
            }
            
            $htmlBody .= '</ul>';
        }
        
        // Send email
        $emailSent = sendPostmarkEmail(
            $formData['email'],
            $subject,
            $htmlBody,
            $textBody
        );
        
        if ($emailSent) {
            $response['success'] = true;
            $response['message'] = 'Thank you! Your submission has been received.';
        } else {
            $response['message'] = 'Form submitted but email notification failed.';
        }
        
    } catch (Exception $e) {
        $response['message'] = $e->getMessage();
        error_log('Form handler error: ' . $e->getMessage());
    }
    
    // Return JSON response
    header('Content-Type: application/json');
    echo json_encode($response);
    exit;
}

// If not POST, return method not allowed
http_response_code(405);
echo json_encode(['success' => false, 'message' => 'Method not allowed']);
?>
EOF

# Copy server management scripts from your GitHub repo
echo "Installing server management scripts..."
cp /opt/server-configs/create-site.sh /root/
cp /opt/server-configs/backup-sites.sh /root/
cp /opt/server-configs/server-monitor.sh /root/
cp /opt/server-configs/form-secrets.template /root/.form-secrets
cp /opt/server-configs/Caddyfile.template /etc/caddy/Caddyfile

chmod +x /root/create-site.sh
chmod +x /root/backup-sites.sh  
# Create server update script that includes Git repo updates
cat > /root/update-server.sh << 'EOF'
#!/bin/bash

echo "Updating server packages..."
apt update && apt upgrade -y && apt autoremove -y && apt autoclean

echo "Updating configuration files from GitHub..."
cd /opt/server-configs
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
EOF

chmod +x /root/update-server.sh
chmod 600 /root/.form-secrets

# Set up log rotation from your GitHub repo
echo "Setting up log rotation..."
cp /opt/server-configs/logrotate-caddy-sites /etc/logrotate.d/caddy-sites

# Set up cron jobs
(crontab -l 2>/dev/null; echo "0 2 * * * /root/backup-sites.sh >/dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "*/15 * * * * /root/server-monitor.sh >/dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "0 4 * * 0 /root/update-server.sh >/dev/null 2>&1") | crontab -

# Set up bash aliases
cat >> /root/.bashrc << 'EOF'

# Alpha Omega Strategies Server Management
alias create-site='/root/create-site.sh'
alias backup-sites='/root/backup-sites.sh'
alias update-server='/root/update-server.sh'
alias monitor-server='tail -f /var/log/server-monitor.log'
alias check-sites='ls -la /var/www/'
alias caddy-reload='caddy reload --config /etc/caddy/Caddyfile'
alias caddy-logs='journalctl -u caddy -f'
EOF

# Reload Caddy with new configuration
systemctl reload caddy

# Final permissions
chown -R www-data:www-data /var/www
chmod -R 755 /var/www
chmod 644 /var/www/form-handler.php

echo ""
echo "========================================="
echo "Debian 12 Server Setup Complete!"
echo "========================================="
echo "Services installed and configured:"
echo "- Caddy web server with auto-SSL"
echo "- PHP 8.2 FPM"
echo "- Hugo static site generator"
echo "- Grav CMS with plugins:"
echo "  * Admin, Form, Email, Postmark"
echo "  * Table Importer, Cloudflare Manager"
echo "- Universal PHP form handler"
echo "- UFW Firewall + Fail2Ban"
echo "- Automated backups and monitoring"
echo ""
echo "Available commands:"
echo "- create-site domain.com [grav|hugo]"
echo "- backup-sites"
echo "- update-server"
echo "- monitor-server"
echo ""
echo "Default Grav CMS accessible at: http://YOUR-IP"
echo "Admin panel: http://YOUR-IP/admin"
echo ""
echo "Next steps:"
echo "1. Edit /root/.form-secrets with your API credentials"
echo "2. Point a domain to this server's IP"
echo "3. Create your first site with: create-site yourdomain.com"
echo "4. SSL certificates will be automatically generated"
echo ""
echo "Form handler available at: /form-handler.php"
echo "Logs stored in: /var/log/forms/"
echo "========================================="
