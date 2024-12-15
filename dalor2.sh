#!/bin/bash

# Set variables
MYSQL_ROOT_PASSWORD=""
RADIUS_DB_PASSWORD="PASSWORD"
ADMIN_USER="administrator"
ADMIN_PASS="mypassw"

# Function to check command execution
check_execution() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed"
        exit 1
    fi
}

# Update and install required packages
sudo apt update && sudo apt -y upgrade
sudo apt -y install apache2 vim php libapache2-mod-php php-gd php-common php-mail php-mail-mime \
    php-mysql php-pear php-db php-mbstring php-xml php-curl php-zip mariadb-server git
check_execution "Package installation"

# Secure MariaDB installation
sudo mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
check_execution "MariaDB secure installation"

# Create RADIUS database and user
sudo mysql -u root -p${MYSQL_ROOT_PASSWORD} <<EOF
CREATE DATABASE radius;
GRANT ALL ON radius.* TO radius@localhost IDENTIFIED BY '${RADIUS_DB_PASSWORD}';
FLUSH PRIVILEGES;
EOF
check_execution "Database creation"

# Install and configure FreeRADIUS
sudo apt -y install freeradius freeradius-mysql freeradius-utils
check_execution "FreeRADIUS installation"

# Import RADIUS schema
sudo mysql -u root -p${MYSQL_ROOT_PASSWORD} radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql
check_execution "Schema import"

# Clone and import daloRADIUS schemas
git clone https://github.com/lirantal/daloradius.git
cd daloradius
sudo mysql -u root -p${MYSQL_ROOT_PASSWORD} radius < contrib/db/mariadb-daloradius.sql
sudo mysql -u root -p${MYSQL_ROOT_PASSWORD} radius < contrib/db/fr3-mariadb-freeradius.sql
cd ..

# Configure SQL module
sudo ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/
sudo chgrp -h freerad /etc/freeradius/3.0/mods-available/sql
sudo chown -R freerad:freerad /etc/freeradius/3.0/mods-enabled/sql

# Configure SQL settings
sudo sed -i 's/driver = "rlm_sql_null"/driver = "rlm_sql_mysql"/' /etc/freeradius/3.0/mods-enabled/sql
sudo sed -i "s/password = \"radpass\"/password = \"${RADIUS_DB_PASSWORD}\"/" /etc/freeradius/3.0/mods-enabled/sql
check_execution "FreeRADIUS SQL configuration"

# Create test user in RADIUS
sudo mysql -u root -p${MYSQL_ROOT_PASSWORD} radius <<EOF
INSERT INTO radcheck (username, attribute, op, value) VALUES ('${ADMIN_USER}', 'Cleartext-Password', ':=', '${ADMIN_PASS}');
EOF
check_execution "Test user creation"

# Move and configure daloRADIUS
sudo mv daloradius /var/www/
cd /var/www/daloradius/app/common/includes/
sudo cp daloradius.conf.php.sample daloradius.conf.php

# Configure daloRADIUS database connection
sudo sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = '';/\$configValues\['CONFIG_DB_PASS'\] = '${RADIUS_DB_PASSWORD}';/" daloradius.conf.php
sudo chown www-data:www-data daloradius.conf.php

# Create required directories
cd /var/www/daloradius/
sudo mkdir -p var/{log,backup}
sudo chown -R www-data:www-data var

# Configure Apache virtual hosts
sudo tee /etc/apache2/sites-available/daloradius.conf <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/daloradius
    ErrorLog \${APACHE_LOG_DIR}/daloradius-error.log
    CustomLog \${APACHE_LOG_DIR}/daloradius-access.log combined

    <Directory /var/www/daloradius>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

# Enable Apache configuration
sudo a2ensite daloradius.conf
sudo a2dissite 000-default.conf
sudo mkdir -p /var/log/apache2/daloradius/{operators,users}

# Set proper permissions
sudo chown -R www-data:www-data /var/www/daloradius

# Restart services
sudo systemctl restart apache2 freeradius
check_execution "Service restart"

# Test RADIUS authentication
echo "Testing RADIUS authentication..."
radtest ${ADMIN_USER} ${ADMIN_PASS} localhost 0 testing123

echo "Installation completed. Access daloRADIUS at http://your-server-ip/"
