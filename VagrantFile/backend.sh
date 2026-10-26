#!/bin/bash
APP_DB_PASS='CHANGE_ME'
APP_MQ_PASS='CHANGE_ME'

# Memcache
dnf install epel-release -y
dnf install memcached -y
sed -i 's/^OPTIONS=.*/OPTIONS="-l 192.168.56.14"/' /etc/sysconfig/memcached
systemctl start memcached
systemctl enable memcached
systemctl status memcached
systemctl start firewalld
systemctl enable firewalld
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.56.12" port port="11211" protocol="tcp" accept' --permanent
firewall-cmd --reload


# Rabbit
dnf install socat -y
# Primary RabbitMQ signing key
rpm --import 'https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc'
# Modern Erlang repository
rpm --import 'https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key'
# RabbitMQ server repository
rpm --import 'https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key'

cat > /etc/yum.repos.d/rabbitmq.repo <<'EOF'
[modern-erlang]
name=modern-erlang-el9
baseurl=https://yum1.rabbitmq.com/erlang/el/9/$basearch
        https://yum2.rabbitmq.com/erlang/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[modern-erlang-noarch]
name=modern-erlang-el9-noarch
baseurl=https://yum1.rabbitmq.com/erlang/el/9/noarch
        https://yum2.rabbitmq.com/erlang/el/9/noarch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-el9]
name=rabbitmq-el9
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/$basearch
        https://yum1.rabbitmq.com/rabbitmq/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-el9-noarch]
name=rabbitmq-el9-noarch
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/noarch
        https://yum1.rabbitmq.com/rabbitmq/el/9/noarch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md
EOF

dnf update -y
dnf install -y logrotate
dnf install -y erlang rabbitmq-server

systemctl start rabbitmq-server
systemctl enable rabbitmq-server
systemctl status rabbitmq-server
rabbitmqctl delete_user guest
rabbitmqctl add_user queue_form "$APP_MQ_PASS"
rabbitmqctl set_permissions -p / queue_form ".*" ".*" ".*"
systemctl restart rabbitmq-server
systemctl start firewalld
systemctl enable firewalld
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.56.12" port port="5672" protocol="tcp" accept' --permanent
firewall-cmd --reload

# Mysql
dnf install mariadb-server -y

# Starting & enabling mariadb-server
systemctl start mariadb
systemctl enable mariadb

# Allow MySQL app server
systemctl start firewalld
systemctl enable firewalld
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.56.12" port port="3306" protocol="tcp" accept' --permanent
firewall-cmd --reload

# MySQL Secure Installation
mysql -u root -e "DROP USER IF EXISTS 'root'@'%';"
mysql -u root -e "DROP USER IF EXISTS ''@'localhost';"
mysql -u root -e "DROP DATABASE IF EXISTS test"
mysql -u root -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%'"
mysql -u root -e "FLUSH PRIVILEGES"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS leads"
mysql -u root -e "grant INSERT on leads.* TO 'contact_form'@'app01' identified by '$APP_DB_PASS'"
mysql -u root -e "CREATE TABLE IF NOT EXISTS leads.contact_form (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(50) NOT NULL,
  company_name VARCHAR(200) NOT NULL,
  email VARCHAR(100) NOT NULL,
  phone VARCHAR(50) NOT NULL,
  created DATETIME DEFAULT CURRENT_TIMESTAMP)"
mysql -u root -e "FLUSH PRIVILEGES"

# Restart mariadb-server
systemctl restart mariadb