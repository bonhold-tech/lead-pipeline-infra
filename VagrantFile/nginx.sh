#!/bin/bash
# web01 - Nginx reverse proxy (Ubuntu 20.04)

# DNS fix for the generic/ubuntu2004 box (DNSSEC=yes with 4.2.2.x servers breaks apt)
sed -i 's/^#\?DNS=.*/DNS=1.1.1.1 8.8.8.8/' /etc/systemd/resolved.conf
sed -i 's/^#\?DNSSEC=.*/DNSSEC=no/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved

# Install Nginx (no apt upgrade - it fills up the small /boot partition)
apt-get update
apt-get install -y nginx

# Reverse proxy to the Python app on app01 (port 8000 - TO DECIDE)
cat > /etc/nginx/sites-available/leadapp <<'EOF'
upstream leadapp {
    server 192.168.56.12:8000;
}

server {
    listen 80;

    location / {
        proxy_pass http://leadapp;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/leadapp /etc/nginx/sites-enabled/leadapp

# Check the config, then start Nginx
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# Firewall: allow SSH first (so vagrant ssh keeps working), then HTTP
ufw allow OpenSSH
ufw --force enable
ufw allow 80/tcp

# TODO (from the project doc): HTTPS with a self-signed certificate, limit_req