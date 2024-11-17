#!/bin/bash

# DaloRADIUS installation script for Ubuntu 22.04
# Run this script as root or with sudo privileges

# Set passwords
MYSQL_ROOT_PASS="MySQLRoot@2024"
RADIUS_DB_PASS="RadiusDB@2024"
DALORADIUS_ADMIN_PASS="AdminPass@2024"

# Exit on error
set -e

# Update system
echo "Updating system..."
apt update && apt upgrade -y

# Install required packages
echo "Installing required packages..."
apt install -y apache2 mariadb-server php php-mysql php-gd php-common \
    php-mail php-mail-mime php-curl php-cli php-zip php-ldap php-mbstring \
    php-xml freeradius freeradius-mysql freeradius-utils git unzip

# Secure MariaDB installation
echo "Configuring MariaDB..."
mysql -e "SET PASSWORD FOR root@localhost = PASSWORD('${MYSQL_ROOT_PASS}');"
mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -e "FLUSH PRIVILEGES;"

# Create radius database and user
echo "Creating radius database..."
mysql -u root -p${MYSQL_ROOT_PASS} -e "CREATE DATABASE radius;"
mysql -u root -p${MYSQL_ROOT_PASS} -e "GRANT ALL ON radius.* TO 'radius'@'localhost' IDENTIFIED BY '${RADIUS_DB_PASS}';"
mysql -u root -p${MYSQL_ROOT_PASS} -e "FLUSH PRIVILEGES;"

# Import radius schema
echo "Importing radius schema..."
mysql -u root -p${MYSQL_ROOT_PASS} radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql

# Configure FreeRADIUS
echo "Configuring FreeRADIUS..."
cd /etc/freeradius/3.0/mods-enabled/
ln -s ../mods-available/sql sql
cd ../sites-enabled/
ln -s ../sites-available/default default

# Update sql module configuration
sed -i 's/dialect = "sqlite"/dialect = "mysql"/' /etc/freeradius/3.0/mods-enabled/sql
sed -i 's/#\s*server = "localhost"/server = "localhost"/' /etc/freeradius/3.0/mods-enabled/sql
sed -i 's/#\s*port = 3306/port = 3306/' /etc/freeradius/3.0/mods-enabled/sql
sed -i 's/#\s*login = "radius"/login = "radius"/' /etc/freeradius/3.0/mods-enabled/sql
sed -i 's/#\s*password = "radpass"/password = "'${RADIUS_DB_PASS}'"/' /etc/freeradius/3.0/mods-enabled/sql

# Install daloRADIUS
echo "Installing daloRADIUS..."
cd /var/www/html
wget https://github.com/lirantal/daloradius/archive/master.zip
unzip master.zip
mv daloradius-master daloradius
rm master.zip
cd daloradius
mysql -u root -p${MYSQL_ROOT_PASS} radius < contrib/db/fr2-mysql-daloradius-and-freeradius.sql
mysql -u root -p${MYSQL_ROOT_PASS} radius < contrib/db/mysql-daloradius.sql

# Configure daloRADIUS
cp contrib/configs/daloradius.conf.php library/
sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = '';/\$configValues\['CONFIG_DB_PASS'\] = '${RADIUS_DB_PASS}';/" library/daloradius.conf.php

# Set daloRADIUS admin password
DALORADIUS_ADMIN_PASS_MD5=$(echo -n "${DALORADIUS_ADMIN_PASS}" | md5sum | cut -d ' ' -f 1)
mysql -u root -p${MYSQL_ROOT_PASS} radius -e "UPDATE operators SET password='${DALORADIUS_ADMIN_PASS_MD5}' WHERE username='administrator';"

# Set permissions
chown -R www-data:www-data /var/www/html/daloradius
chmod 644 /var/www/html/daloradius/library/daloradius.conf.php

# Restart services
systemctl restart mariadb
systemctl restart freeradius
systemctl restart apache2

echo "Installation completed!"
echo "-----------------------------------"
echo "MySQL root password: ${MYSQL_ROOT_PASS}"
echo "RADIUS DB password: ${RADIUS_DB_PASS}"
echo "DaloRADIUS admin credentials:"
echo "Username: administrator"
echo "Password: ${DALORADIUS_ADMIN_PASS}"
echo "-----------------------------------"
echo "Access daloRADIUS at: http://your-server-ip/daloradius"
