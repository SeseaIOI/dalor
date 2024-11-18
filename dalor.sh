#!/bin/bash

# Exit on error
set -e

# Configuration variables
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 8)
RADIUS_DB_PASSWORD=$(openssl rand -hex 8)
DALORADIUS_VERSION="1.2"
SERVER_IP=$(hostname -I | cut -d' ' -f1)
APACHE_PORT=8080

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Save credentials to a file
save_credentials() {
    cat > /root/radius_credentials.txt <<EOF
FreeRADIUS Installation Credentials
==================================
Date: $(date)
Server IP: $SERVER_IP

Database Credentials:
-------------------
MySQL Root Password: $MYSQL_ROOT_PASSWORD
Radius DB User: radius
Radius DB Password: $RADIUS_DB_PASSWORD

DaloRADIUS Web Interface:
-----------------------
URL: http://$SERVER_IP:$APACHE_PORT/daloradius
Username: administrator
Password: radius

Please store this information securely!
EOF
    chmod 600 /root/radius_credentials.txt
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log "Please run as root"
    exit 1
fi

# Update system
log "Updating system packages..."
apt-get update
apt-get upgrade -y

# Install required packages
log "Installing required packages..."
apt-get install -y mariadb-server freeradius freeradius-mysql apache2 \
    php php-mysql php-gd php-common php-mail php-mail-mime php-mysql \
    php-pear php-db php-mbstring php-xml php-zip php-curl libapache2-mod-php \
    unzip wget git

# Enable Apache modules
log "Enabling Apache modules..."
a2enmod php
a2enmod rewrite

# Configure PHP
log "Configuring PHP..."
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
cat > /etc/php/$PHP_VERSION/apache2/php.ini <<EOF
[PHP]
display_errors = On
error_reporting = E_ALL & ~E_NOTICE & ~E_DEPRECATED
max_execution_time = 300
memory_limit = 128M
post_max_size = 32M
upload_max_filesize = 32M
date.timezone = UTC

[Session]
session.gc_maxlifetime = 14400
session.gc_probability = 1
session.gc_divisor = 1
EOF

# Configure MariaDB
log "Configuring MariaDB..."
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
CREATE DATABASE IF NOT EXISTS radius;
GRANT ALL ON radius.* TO 'radius'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASSWORD';
FLUSH PRIVILEGES;
EOF

# Import schema
log "Importing radius schema..."
mysql -u root -p$MYSQL_ROOT_PASSWORD radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql

# Configure FreeRADIUS
log "Configuring FreeRADIUS..."
cp /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-available/sql.orig

cat > /etc/freeradius/3.0/mods-available/sql <<EOF
sql {
    driver = "rlm_sql_mysql"
    dialect = "mysql"
    server = "localhost"
    port = 3306
    login = "radius"
    password = "$RADIUS_DB_PASSWORD"
    radius_db = "radius"
    
    read_groups = yes
    read_profiles = yes
    
    encryption_scheme = clear
}
EOF

# Remove existing symbolic links if they exist
log "Cleaning up existing symbolic links..."
rm -f /etc/freeradius/3.0/mods-enabled/sql
rm -f /etc/freeradius/3.0/sites-enabled/default

# Create new symbolic links
log "Creating new symbolic links..."
ln -s /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/
ln -s /etc/freeradius/3.0/sites-available/default /etc/freeradius/3.0/sites-enabled/

# Install daloRADIUS
log "Installing daloRADIUS..."
cd /tmp
wget https://github.com/lirantal/daloradius/archive/refs/tags/$DALORADIUS_VERSION.zip
unzip $DALORADIUS_VERSION.zip
rm -rf /var/www/html/*
mv daloradius-$DALORADIUS_VERSION/* /var/www/html/daloradius/

# Configure Apache port
log "Configuring Apache to listen on port $APACHE_PORT..."
sed -i "s/Listen 80/Listen $APACHE_PORT/" /etc/apache2/ports.conf

# Create Apache configuration for daloRADIUS
cat > /etc/apache2/sites-available/000-default.conf <<EOF
<VirtualHost *:$APACHE_PORT>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/daloradius
    DirectoryIndex index.php
    
    <Directory /var/www/html/daloradius>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
        php_flag display_errors on
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Configure daloRADIUS
cd /var/www/html/daloradius
mysql -u root -p$MYSQL_ROOT_PASSWORD radius < contrib/db/fr2-mysql-daloradius-and-freeradius.sql
mysql -u root -p$MYSQL_ROOT_PASSWORD radius < contrib/db/mysql-daloradius.sql

cp library/daloradius.conf.php.sample library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_USER'\] = 'root';/\$configValues\['CONFIG_DB_USER'\] = 'radius';/" library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = '';/\$configValues\['CONFIG_DB_PASS'\] = '$RADIUS_DB_PASSWORD';/" library/daloradius.conf.php

# Set proper permissions
log "Setting correct permissions..."
chown -R www-data:www-data /var/www/html/daloradius
chmod -R 755 /var/www/html/daloradius
find /var/www/html/daloradius -type f -exec chmod 644 {} \;
find /var/www/html/daloradius -type d -exec chmod 755 {} \;

# Create and set permissions for log directory
mkdir -p /var/log/daloradius
touch /var/log/daloradius/daloradius.log
chown -R www-data:www-data /var/log/daloradius
chmod 755 /var/log/daloradius
chmod 644 /var/log/daloradius/daloradius.log

# Restart services
log "Restarting services..."
systemctl restart apache2
systemctl restart freeradius
systemctl enable freeradius
systemctl enable apache2

# Save credentials
save_credentials

# Display installation summary
log "Installation complete! Here's your installation summary:"
echo "============================================"
echo "FreeRADIUS and daloRADIUS have been installed!"
echo "============================================"
echo "DaloRADIUS Web Interface:"
echo "URL: http://$SERVER_IP:$APACHE_PORT/daloradius"
echo "Username: administrator"
echo "Password: radius"
echo ""
echo "All credentials have been saved to: /root/radius_credentials.txt"
echo "============================================"
echo "If you experience any issues, check these logs:"
echo "Apache error log: tail -f /var/log/apache2/error.log"
echo "DaloRADIUS log: tail -f /var/log/daloradius/daloradius.log"
echo "FreeRADIUS log: tail -f /var/log/freeradius/radius.log"
echo "============================================"

# Test PHP processing
log "Testing PHP processing..."
cat > /var/www/html/daloradius/test.php <<EOF
<?php
phpinfo();
EOF

echo "To test PHP processing, visit: http://$SERVER_IP:$APACHE_PORT/daloradius/test.php"
