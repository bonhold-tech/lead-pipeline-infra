#!/bin/bash
# app01 - Python lead app: Flask web app, RabbitMQ consumer, Mailpit (CentOS Stream 9)
# The app code (app/ folder) is uploaded to /tmp/leadapp-src by the Vagrant "file" provisioner
# The passwords must be the same as in mysql.sh (APP_DB_PASS) and rabbitmq.sh (APP_MQ_PASS)
APP_DB_PASS='CHANGE_ME'
APP_MQ_PASS='CHANGE_ME'
LEAD_NOTIFY_TO='CHANGE_ME@example.com'

# Mailpit release and its SHA-256 (asset digest shown by GitHub on the release page)
MAILPIT_VERSION='v1.31.6'
MAILPIT_SHA256='10fa12ccc610f653d4ed4df848c1817f9935dcf4e9a6a458a19ab0fa02093f91'

# Install Python 3 (venv is part of it) and tools for the Mailpit download
dnf install -y python3 curl tar

# System user that runs the app: no home directory, no login shell
if ! id leadapp > /dev/null 2>&1; then
  useradd --system --no-create-home --shell /sbin/nologin leadapp
fi

# Copy the app code to /opt/leadapp
# Files stay owned by root, so the leadapp user can run the code but not change it
mkdir -p /opt/leadapp
cp /tmp/leadapp-src/app.py /tmp/leadapp-src/consumer.py /tmp/leadapp-src/requirements.txt /opt/leadapp/
chown -R root:root /opt/leadapp
chmod 644 /opt/leadapp/app.py /opt/leadapp/consumer.py /opt/leadapp/requirements.txt
# Remove the upload, so the next "vagrant provision" uploads a fresh copy
rm -rf /tmp/leadapp-src

# Python virtual environment with the pinned packages
python3 -m venv /opt/leadapp/venv
/opt/leadapp/venv/bin/pip install -r /opt/leadapp/requirements.txt

# Settings and secrets, loaded by systemd (EnvironmentFile=) - readable by root only
cat > /etc/leadapp.env <<EOF
# Read by systemd for the leadapp-web and leadapp-consumer services
DB_HOST=db01
DB_NAME=leads
DB_USER=contact_form
APP_DB_PASS=$APP_DB_PASS
MQ_HOST=rmq01
MQ_USER=queue_form
APP_MQ_PASS=$APP_MQ_PASS
MC_HOST=mc01
SMTP_HOST=127.0.0.1
SMTP_PORT=1025
LEAD_NOTIFY_FROM=leadapp@app01.lab
LEAD_NOTIFY_TO=$LEAD_NOTIFY_TO
EOF
chown root:root /etc/leadapp.env
chmod 600 /etc/leadapp.env

# Mailpit: test SMTP server, catches all emails (nothing goes to the internet)
# Download, check the SHA-256, and only then install the binary
if [ ! -x /usr/local/bin/mailpit ]; then
  curl -fsSL -o /tmp/mailpit.tar.gz "https://github.com/axllent/mailpit/releases/download/$MAILPIT_VERSION/mailpit-linux-amd64.tar.gz"
  if ! echo "$MAILPIT_SHA256  /tmp/mailpit.tar.gz" | sha256sum -c -; then
    echo "ERROR: Mailpit checksum does not match - not installing it" >&2
    rm -f /tmp/mailpit.tar.gz
    exit 1
  fi
  tar -xzf /tmp/mailpit.tar.gz -C /usr/local/bin mailpit
  rm -f /tmp/mailpit.tar.gz
fi

# systemd unit: Mailpit (SMTP on localhost only, web UI on 8025)
cat > /etc/systemd/system/mailpit.service <<'EOF'
[Unit]
Description=Mailpit test SMTP server
After=network-online.target
Wants=network-online.target

[Service]
User=leadapp
Group=leadapp
# StateDirectory creates /var/lib/mailpit owned by leadapp
StateDirectory=mailpit
ExecStart=/usr/local/bin/mailpit --smtp 127.0.0.1:1025 --listen 0.0.0.0:8025 --database /var/lib/mailpit/mailpit.db
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# systemd unit: web app (gunicorn with 2 workers on port 8000)
cat > /etc/systemd/system/leadapp-web.service <<'EOF'
[Unit]
Description=Lead form web app (gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
User=leadapp
Group=leadapp
WorkingDirectory=/opt/leadapp
EnvironmentFile=/etc/leadapp.env
ExecStart=/opt/leadapp/venv/bin/gunicorn --workers 2 --bind 0.0.0.0:8000 --access-logfile - app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# systemd unit: consumer (restarts automatically if RabbitMQ is not ready yet)
cat > /etc/systemd/system/leadapp-consumer.service <<'EOF'
[Unit]
Description=Lead queue consumer (RabbitMQ -> MariaDB + email)
After=network-online.target mailpit.service
Wants=network-online.target

[Service]
User=leadapp
Group=leadapp
WorkingDirectory=/opt/leadapp
EnvironmentFile=/etc/leadapp.env
ExecStart=/opt/leadapp/venv/bin/python -u consumer.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Start the services (restart so a new provision run picks up code changes)
systemctl daemon-reload
systemctl enable --now mailpit leadapp-web leadapp-consumer
systemctl restart mailpit leadapp-web leadapp-consumer

# Firewall: app port for web01 (Nginx) only, Mailpit UI for my host only
systemctl enable --now firewalld
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.56.11" port port="8000" protocol="tcp" accept' --permanent
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.56.1" port port="8025" protocol="tcp" accept' --permanent
firewall-cmd --reload
