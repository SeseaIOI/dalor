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
    php-pear php-db php-mbstring php-xml php-zip php-curl \
    unzip wget git

# Configure PHP
log "Configuring PHP..."
cat > /etc/php/*/apache2/php.ini <<EOF
display_errors = On
error_reporting = E_ALL & ~E_NOTICE & ~E_DEPRECATED
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
mv daloradius-$DALORADIUS_VERSION /var/www/html/daloradius

# Create required directories
mkdir -p /var/www/html/daloradius/library/
mkdir -p /var/www/html/daloradius/templates/

# Configure daloRADIUS database
cd /var/www/html/daloradius
mysql -u root -p$MYSQL_ROOT_PASSWORD radius < contrib/db/fr2-mysql-daloradius-and-freeradius.sql
mysql -u root -p$MYSQL_ROOT_PASSWORD radius < contrib/db/mysql-daloradius.sql

# Configure daloRADIUS
cp library/daloradius.conf.php.sample library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = '';/\$configValues\['CONFIG_DB_PASS'\] = '$RADIUS_DB_PASSWORD';/" library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_USER'\] = 'root';/\$configValues\['CONFIG_DB_USER'\] = 'radius';/" library/daloradius.conf.php

# Configure Apache port
log "Configuring Apache to listen on port $APACHE_PORT..."
sed -i "s/Listen 80/Listen $APACHE_PORT/" /etc/apache2/ports.conf
sed -i "s/<VirtualHost \*:80>/<VirtualHost *:$APACHE_PORT>/" /etc/apache2/sites-enabled/000-default.conf

# Create Apache configuration for daloRADIUS
cat > /etc/apache2/sites-available/daloradius.conf <<EOF
<VirtualHost *:$APACHE_PORT>
    DocumentRoot /var/www/html/daloradius
    <Directory /var/www/html/daloradius>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        php_flag display_errors on
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/daloradius-error.log
    CustomLog \${APACHE_LOG_DIR}/daloradius-access.log combined
</VirtualHost>
EOF

# Enable the site
a2ensite daloradius.conf

# Set proper permissions
log "Setting correct permissions..."
chown -R freerad:freerad /etc/freeradius/3.0/mods-enabled/sql
chmod 640 /etc/freeradius/3.0/mods-enabled/sql
chown -R www-data:www-data /var/www/html/daloradius/
chmod 644 /var/www/html/daloradius/library/daloradius.conf.php

# Create required directories with proper permissions
mkdir -p /var/log/daloradius/
touch /var/log/daloradius/daloradius.log
chown -R www-data:www-data /var/log/daloradius/

# Fix common daloRADIUS file permission issues
find /var/www/html/daloradius -type f -exec chmod 644 {} \;
find /var/www/html/daloradius -type d -exec chmod 755 {} \;

# Start and enable services
log "Starting services..."
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
echo "Please make sure to secure this file!"
echo "============================================"
echo "To check Apache error logs:"
echo "tail -f /var/log/apache2/daloradius-error.log"
echo "============================================"
echo "To check if services are running:"
echo "systemctl status apache2"
echo "systemctl status freeradius"
echo "============================================"
