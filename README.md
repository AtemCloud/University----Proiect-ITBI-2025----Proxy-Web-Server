# CGI Proxy Server Setup Guide (with Cache Auto-Mount and HTML UI)

This tutorial walks you through configuring Apache to run a CGI proxy script, setting up a cache directory that auto-mounts at boot, and adding a simple HTML page to interact with the proxy.

## 1) Install required packages

On Debian/Ubuntu:
```bash
sudo apt-get update
sudo apt-get install -y apache2 wget inotify-tools
```
- `apache2`: Web server
- `wget`: Fetching remote pages/assets
- `inotify-tools`: Recommended for coordinating concurrent requests

## 2) Enable CGI in Apache

```bash
sudo a2enmod cgi
sudo systemctl restart apache2
```

If your site needs explicit CGI handling, add (or verify) this in your VirtualHost:
```apache
# /etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
    ServerName your-hostname

    # Serve CGI scripts from the system cgi-bin
    ScriptAlias /cgi-bin/ /usr/lib/cgi-bin/

    <Directory "/usr/lib/cgi-bin">
        Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
        Require all granted
        AddHandler cgi-script .cgi .pl .py .sh
    </Directory>

    # Static site root for your HTML UI
    DocumentRoot /var/www/html
    <Directory "/var/www/html">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
```

Reload Apache:
```bash
sudo systemctl reload apache2
```

## 3) Deploy the CGI script

Place your CGI script (e.g., `proxy.sh`) in the system CGI directory and make it executable:
```bash
sudo cp proxy.sh /usr/lib/cgi-bin/proxy.sh
sudo chmod +x /usr/lib/cgi-bin/proxy.sh
```
Note: The script itself is not included here. Ensure it prints `Content-Type: text/html` and handles `?url=` query parameters.

## 4) Create and permission the cache directory

By convention, use `/mnt/proxy-cache`:
```bash
sudo mkdir -p /mnt/proxy-cache
sudo chown -R www-data:www-data /mnt/proxy-cache
sudo chmod -R 750 /mnt/proxy-cache
```
- `www-data` is the default Apache user/group on Debian/Ubuntu.

## 5) Auto-mount the cache on boot

Choose one option based on your needs:

### Option A: RAM-backed cache (tmpfs)
Fast but volatile (clears on reboot).
1. Add to `/etc/fstab`:
   ```fstab
   tmpfs /mnt/proxy-cache tmpfs defaults,size=512M,mode=0750,uid=www-data,gid=www-data 0 0
   ```
2. Apply:
   ```bash
   sudo mount -a
   df -h /mnt/proxy-cache
   ```

## 6) Set up the HTML UI

Create a simple UI page that lets you paste a URL and either navigate through the proxy or show it in an iframe.

- Place `index.html` under `/var/www/html/`.
- The UI will URL-encode the input and call `/cgi-bin/proxy.sh?url=...`.
- Optional: include a prefetch mode selector (e.g., `pf=assets` or `pf=lazy`) if your CGI script supports it.

See the sample in `index.html` below.

## 7) Test

Open in a browser:
- UI: `http://<server>/`
- Direct proxy call: `http://<server>/cgi-bin/proxy.sh?url=https%3A%2F%2Fwww.example.com%2F`

Verify:
- Cache directories appear under `/mnt/proxy-cache/<sha256-of-url>/`
- Apache logs: `/var/log/apache2/error.log`, `/var/log/apache2/access.log`

## 8) Maintenance and troubleshooting

- Clear a single URL’s cache:
  ```bash
  sudo rm -rf /mnt/proxy-cache/<hash>
  ```
- Clear all caches:
  ```bash
  sudo rm -rf /mnt/proxy-cache/*
  ```
- Permissions:
  - Ensure `/mnt/proxy-cache` ownership is `www-data:www-data`.
  - For tmpfs/systemd mounts, set `mode`, `uid`, and `gid` options correctly.

## Security notes

- Restrict access if exposing publicly (IP allow-list, auth).
- Sanitize the `url` parameter and enforce `http/https`.
- Respect site terms and robots.txt; prefetch can be bandwidth-heavy.

---
You are ready to run the CGI proxy with a cache that auto-mounts on boot and a simple front-end HTML UI.
