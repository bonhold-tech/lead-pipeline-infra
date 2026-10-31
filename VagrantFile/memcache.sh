#!/bin/bash
# mc01 - Memcached (CentOS Stream 9)

# Install Memcached
dnf install -y memcached

# Listen on the mc01 address instead of localhost only
sed -i 's/^OPTIONS=.*/OPTIONS="-l 192.168.56.14"/' /etc/sysconfig/memcached

# Start Memcached (restart so it picks up the new OPTIONS)
systemctl enable --now memcached
systemctl restart memcached

# Firewall: Memcached port open for app01 only
systemctl enable --now firewalld
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.56.12" port port="11211" protocol="tcp" accept' --permanent
firewall-cmd --reload