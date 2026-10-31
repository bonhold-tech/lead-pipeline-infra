#!/bin/bash
# db01 - MariaDB (CentOS Stream 9)
APP_DB_PASS='CHANGE_ME'

# Install and start MariaDB
dnf install -y mariadb-server
systemctl enable --now mariadb

# Firewall: database port open for app01 only
systemctl enable --now firewalld
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.56.12" port port="3306" protocol="tcp" accept' --permanent
firewall-cmd --reload

# MySQL secure installation
mysql -u root -e "DROP USER IF EXISTS 'root'@'%'"
mysql -u root -e "DROP USER IF EXISTS ''@'localhost'"
mysql -u root -e "DROP DATABASE IF EXISTS test"
mysql -u root -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%'"
mysql -u root -e "FLUSH PRIVILEGES"

# Database, table and app user
mysql -u root -e "CREATE DATABASE IF NOT EXISTS leads"
mysql -u root -e "CREATE TABLE IF NOT EXISTS leads.contact_form (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(50) NOT NULL,
  company_name VARCHAR(200) NOT NULL,
  email VARCHAR(100) NOT NULL,
  phone VARCHAR(50) NOT NULL,
  created DATETIME DEFAULT CURRENT_TIMESTAMP)"
mysql -u root -e "GRANT INSERT ON leads.* TO 'contact_form'@'app01' IDENTIFIED BY '$APP_DB_PASS'"