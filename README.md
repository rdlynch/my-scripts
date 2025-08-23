# Alpha Omega Strategies Server Configuration

## Purpose

These scripts provision and manage a small Debian 12 VPS at Linode for accessible, production hosting of static Hugo sites and per-site Grav installs behind Caddy. The design favors security, simplicity, and low maintenance.

## Conventions and paths

The repo is cloned to `/opt/server-scripts`. Sites live in `/var/www/<domain>`. Caddy site logs are JSON at `/var/log/caddy/<domain>.log`. Daily site backups go to `/var/backups/sites/<domain>`. Form logs are in `/var/log/forms`.

## One-time bootstrap

Linode’s fresh image requires the first three commands by hand. Run:

```
apt update && apt upgrade -y && apt install -y git
git clone https://example.com/your/repo.git /opt/server-scripts
cd /opt/server-scripts
sudo ./server-setup.sh
```

The setup script hardens SSH, enables UFW, installs Caddy and PHP-FPM 8.2, configures Fail2ban, unattended-upgrades, creates standard directories, and installs systemd timers for backups, updates, and monitoring. It deploys the Caddyfile template and optional components if present in the repo.

## Creating a site

Use `create-site` with a domain and type. Hugo uses artifact-only deploys. Grav installs per site.

```
sudo create-site domain.com hugo
```

This creates `/var/www/domain.com/public`, writes a Caddy block with JSON logging, validates, and reloads Caddy. For Grav, pass `grav` instead of `hugo` and the script installs Grav into the site root, sets safe permissions, wires PHP-FPM, and reloads Caddy.

## Hugo workflow on Windows 11 (artifact-only)

Create and edit your Hugo project locally, build, then mirror the `public` output to the server. No build runs on the VPS.

Local example:

```
mkdir C:\sites\domain.com
hugo new site C:\sites\domain.com
cd C:\sites\domain.com
hugo server -D
hugo --minify
```

Upload the contents of `C:\sites\domain.com\public` to `/var/www/domain.com/public` using an FTP/SFTP client with a mirror sync. Files are served immediately by Caddy. Nothing runs on the server.

## Backups

Backups run daily at 02:00 via a systemd timer. The script detects site type and includes only what matters. Hugo backups archive `/public` because you build locally. Grav backups archive the whole site and exclude cache and on-site backups to reduce size. Each archive is verified, a SHA256 is written, and anything older than 14 days is pruned. The script throttles disk activity so it does not fight Caddy or PHP-FPM.

Manual run:

```
sudo backup-sites
```

Restore is straightforward. Extract the archive for the target domain back into `/var/www/<domain>` or its `public` folder for Hugo, then set ownership to `www-data:www-data` and permissions to 755 on directories and 644 on files. Reload Caddy if you restored a Grav site and adjusted PHP routing.

## Updates and weekly maintenance

Automatic weekly updates run Sunday at 04:00. The script performs `apt full-upgrade`, validates the Caddyfile before reload, and restarts PHP-FPM and Fail2ban. If a new kernel is present or a reboot flag exists, it schedules a reboot a few minutes out. You can disable auto-reboot by setting `ALLOW_REBOOT=no` on the unit or environment.

Manual run:

```
sudo server-update
```

Logs are in `/var/log/aos-update.log`.

## Monitoring

The monitor timer runs every 15 minutes. It checks Caddy, PHP-FPM, Fail2ban, UFW, validates the Caddyfile, inspects disk and inode usage, free memory and swap, load vs core count, looks for oversize Caddy logs, and evaluates TLS expiry from Caddy’s cert store. Results are written to `/var/log/aos-monitor.log`. Non-zero exit codes indicate warnings or critical issues, which you can wire to alerts later.

Manual run:

```
sudo server-monitor
```

## Security controls

SSH is configured to disallow password auth and prohibit direct root login by password. UFW only allows SSH, HTTP, and HTTPS. Fail2ban protects SSH and Caddy endpoints. The Caddy admin API binds to localhost. PHP-FPM is tuned conservatively for a 4 GB node with OPcache enabled. JSON access logs per site enable precise Fail2ban filtering.

## Fail2ban and Caddy logs

Caddy writes JSON logs under `/var/log/caddy/<domain>.log`, with rotation handled by Caddy itself. Logrotate compresses and ages out rotated files without touching the active ones. The `caddy-auth` jail bans repeat 401 or 403 responses and blocks scanners probing paths like `/.env` or `/wp-login.php`.

Basic checks:

```
sudo fail2ban-client status caddy-auth
sudo fail2ban-regex /var/log/caddy/theruralgrantguy.com.log /etc/fail2ban/filter.d/caddy-auth.conf --print-all-matched
```

## Forms and email

The secure form handler is installed at `/var/www/form-handler.php`. Configuration lives at `/etc/aos-form-secrets` and controls recipients, origin checks, anti-abuse, logging, and email transport. Default transport is the Postmark HTTP API with automatic SMTP fallback using the same Server token.

Minimal form example:

```
<form action="/form-handler.php" method="post" enctype="multipart/form-data">
  <label>Name <input name="name" required></label>
  <label>Email <input name="email" type="email" required></label>
  <label>Message <textarea name="message" required></textarea></label>
  <input type="text" name="website" autocomplete="off" tabindex="-1" aria-hidden="true" style="position:absolute;left:-10000px;">
  <input type="hidden" name="ts" id="ts">
  <button type="submit">Send</button>
</form>
<script>document.getElementById('ts').value = Math.floor(Date.now()/1000);</script>
```

The handler returns JSON with clear HTTP codes. Use curl for a quick test:

```
curl -i -X POST https://theruralgrantguy.com/form-handler.php \
  -d "name=Test User" -d "email=you@example.com" -d "message=Hello"
```

Logs are JSON lines at `/var/log/forms/contact.log` with sensitive fields redacted.

## DNS and TLS

Point the domain’s A record to the VPS. CNAME `www` to the apex if needed. Caddy manages certificate issuance and renewal automatically using Let’s Encrypt, with your ACME email set in the global `Caddyfile`. Certificate expiry is checked by the monitor and will be logged if the remaining days drop below thresholds.

## Optional cloud backup to Backblaze B2

If you want off-site copies of archives, use rclone with a bucket-scoped Application Key. Store the rclone config at `/root/.config/rclone/rclone.conf` with 0600 permissions. Use `/etc/aos-backup.env` for non-secret settings like the remote name and path prefix. After you add these, the backup script can push verified tarballs to B2 at the end of a successful run. This is optional and not enabled by default.

## Troubleshooting

Validate the Caddyfile before any manual reloads:

```
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Check timers:

```
systemctl list-timers | grep aos-
```

Review service status:

```
systemctl status caddy php8.2-fpm fail2ban
```

Inspect recent monitor entries for early warnings:

```
tail -200 /var/log/aos-monitor.log
```

## Accessibility notes

Admin output is plain text with clear headings and no decorative characters. JSON logs are line-delimited for reliable screen reader parsing. The sample form uses visible labels, proper field types, and avoids visual-only cues. CAPTCHA is optional and can be set to Turnstile, hCaptcha, reCAPTCHA, or none in the secrets file. Start with all non-CAPTCHA defenses and only enable a provider if real abuse appears.

## Script index

`server-setup.sh` provisions the server and installs timers.
`create-site.sh` creates either a Hugo site (artifact-only) or a Grav site per domain.
`backup-sites.sh` archives sites safely with verification and retention.
`server-update.sh` runs weekly maintenance with controlled reloads and reboot logic.
`server-monitor.sh` checks health and resources on a 15-minute schedule.
`jail.local` enables SSH, Caddy auth, and recidive jails.
`caddy-auth.conf` matches auth failures and scanner probes in JSON logs.
`logrotate-caddy-sites` compresses and ages out rotated logs without touching actives.
`form-secrets.template` configures the handler, email transport, anti-abuse, and logging.
`form-handler.php` validates, rate limits, verifies optional CAPTCHA, sends via Postmark HTTP API with SMTP fallback, and logs outcomes.
