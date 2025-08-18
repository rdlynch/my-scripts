# Alpha Omega Strategies Server Management Scripts

Automated server setup and management scripts for Debian 12 with Caddy, Grav CMS, Hugo, and a universal PHP form handler. Designed for accessibility and professional consulting operations.

## Quick Start

Deploy a complete server in under 15 minutes:

```bash
cd /root && git clone https://github.com/rdlynch/my-scripts.git && cd my-scripts && chmod +x server-setup.sh && ./server-setup.sh
```

## Scripts Overview

### Core Management Scripts

- **`server-setup.sh`** - Complete automated Debian 12 server installation
  - Caddy web server with auto-SSL
  - PHP 8.2 FPM optimized for performance
  - Hugo static site generator
  - Grav CMS (core only, no admin panel for accessibility)
  - Universal form handler with Postmark/B2 integration
  - Security hardening (UFW firewall + Fail2Ban)
  - Automated backups, monitoring, and updates

- **`create-site.sh`** - Create new Grav or Hugo sites with one command
  - Usage: `create-site domain.com [grav|hugo]`
  - Automatic theme installation (Hadron for Grav, Clarity for Hugo)
  - SSL certificate generation
  - Caddy configuration management

- **`backup-sites.sh`** - Automated daily backups (runs at 2 AM)
  - All websites and configurations
  - 14-day retention policy
  - Form submission logs (30 days)
  - Compressed archives with manifests

- **`server-monitor.sh`** - System health monitoring (runs every 15 minutes)
  - Disk, memory, and CPU load monitoring
  - Service status checks (Caddy, PHP, Fail2Ban)
  - SSL certificate expiration alerts
  - Package update notifications

- **`server-update.sh`** - Weekly automated updates (runs Sundays at 4 AM)
  - System package updates
  - Hugo version updates
  - Configuration file synchronization
  - Service restarts as needed

### Core Components

- **`form-handler.php`** - Universal form processor for all sites
  - WCAG 2.2 AA compliant
  - Postmark email integration
  - Backblaze B2 file storage
  - Rate limiting and security validation
  - Works with both Grav and Hugo sites

### Configuration Files

- **`caddyfile.template`** - Base Caddy configuration
- **`jail.local`** - Fail2Ban security rules
- **`caddy-auth.conf`** - Fail2Ban filter for Caddy
- **`logrotate-caddy-sites`** - Log rotation configuration
- **`form-secrets.template`** - API credentials template

## Server Specifications

**Recommended Hardware:**
- Linode 2 vCPU, 4GB RAM, 80GB SSD
- Monthly cost: ~$24

**Stack:**
- Debian 12 LTS
- Caddy 2.x (automatic HTTPS)
- PHP 8.2 FPM
- Hugo (latest extended)
- Grav CMS (core only)

## Available Commands

After installation, these aliases are available:

```bash
create-site domain.com [grav|hugo]  # Create new website
backup-sites                        # Manual backup
update-server                       # Manual update
monitor-server                      # View monitoring log
check-sites                         # List all sites
caddy-reload                        # Reload web server
caddy-logs                          # View web server logs
```

## Directory Structure

```
/var/www/                   # All websites
├── cms/                    # Default Grav site (IP access)
├── sitename/               # Individual sites
└── form-handler.php        # Universal form processor

/var/backups/sites/         # Daily backups (14 days)
/var/log/forms/            # Form submissions (5 years)
/root/my-scripts/          # This repository
```

## Accessibility Features

- **Screen Reader Compatible**: All scripts use accessible text (no Unicode symbols)
- **JAWS Optimized**: Form handler designed for JAWS for Windows
- **WCAG 2.2 AA**: All forms and interfaces meet accessibility standards
- **No Admin Panels**: File-based editing via WinSCP for reliability

## Security Features

- **UFW Firewall**: Only ports 22, 80, 443 open
- **Fail2Ban**: Automatic IP blocking for failed logins
- **Auto-SSL**: Let's Encrypt certificates with auto-renewal
- **Rate Limiting**: Form submission protection
- **Secure Headers**: HSTS, CSP, XSS protection
- **File Validation**: Strict upload controls

## Form Handler Integration

Add to any HTML page for universal form processing:

```html
<form action="/form-handler.php" method="post" enctype="multipart/form-data">
    <input type="email" name="email" required>
    <textarea name="message" required></textarea>
    <input type="file" name="attachment" accept=".pdf,.doc,.docx">
    <button type="submit">Send</button>
</form>
```

Features:
- Email delivery via Postmark
- File uploads to Backblaze B2
- Automatic logging and tracking
- JSON responses for AJAX integration

## Configuration

1. **Set API credentials**: `nano /root/.form-secrets`
2. **Create first site**: `create-site yourdomain.com grav`
3. **Point DNS** to your server IP
4. **SSL certificates** generate automatically

## Professional Use Case

Designed specifically for Alpha Omega Strategies' government contracting and rural development consulting practice:

- **Client Websites**: Professional Grav sites with accessible themes
- **Project Documentation**: Hugo sites for fast, static content
- **Form Processing**: Secure contact forms with file uploads
- **Compliance Ready**: WCAG 2.2 AA accessibility standards
- **Low Maintenance**: Automated backups, updates, and monitoring

## Support

This is a personal server management system. Scripts are provided as-is for educational and professional use.

**Best Practices:**
- Test on staging before production
- Keep API credentials secure
- Monitor logs regularly
- Backup before major changes

---

**Built for accessibility, reliability, and professional consulting operations.**
