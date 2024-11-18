#!/bin/bash

# Exit on error
set -e

# Configuration variables
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 8)
RADIUS_DB_PASSWORD=$(openssl rand -hex 8)
DALORADIUS_VERSION="1.2"
SERVER_IP=$(hostname -I | cut -d' ' -f1)

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
URL: http://$SERVER_IP/daloradius
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
apt-get install -y mariadb-server freeradius freeradius-mysql apache2 php php-mysql \
    php-gd php-common php-mail php-mail-mime php-mysql php-pear php-db php-mbstring php-xml \
    unzip wget

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
# Backup original sql module configuration
cp /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-available/sql.orig

# Configure sql module
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
cd /var/www/html/daloradius
mysql -u root -p$MYSQL_ROOT_PASSWORD radius < contrib/db/fr2-mysql-daloradius-and-freeradius.sql
mysql -u root -p$MYSQL_ROOT_PASSWORD radius < contrib/db/mysql-daloradius.sql

# Configure daloRADIUS
cp /var/www/html/daloradius/library/daloradius.conf.php.sample /var/www/html/daloradius/library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = '';/\$configValues\['CONFIG_DB_PASS'\] = '$RADIUS_DB_PASSWORD';/" /var/www/html/daloradius/library/daloradius.conf.php

# Set proper permissions
log "Setting correct permissions..."
chown -R freerad:freerad /etc/freeradius/3.0/mods-enabled/sql
chmod 640 /etc/freeradius/3.0/mods-enabled/sql
chown -R www-data:www-data /var/www/html/daloradius/
chmod 644 /var/www/html/daloradius/library/daloradius.conf.php

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
echo "URL: http://$SERVER_IP/daloradius"
echo "Username: administrator"
echo "Password: radius"
echo ""
echo "All credentials have been saved to: /root/radius_credentials.txt"
echo "Please make sure to secure this file!"
echo "============================================"
echo "To test FreeRADIUS, you can use the radtest command:"
echo "radtest user password localhost 0 testing123"
echo "============================================"
