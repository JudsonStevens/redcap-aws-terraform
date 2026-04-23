#!/bin/bash

# REDCap EC2 Instance Setup Script
# This script installs and configures REDCap on Amazon Linux 2023

set -e

# Variables from Terraform (non-sensitive)
NAME_PREFIX="${name_prefix}"
AWS_REGION="${aws_region}"
PHP_VERSION="${php_version}"
DB_ENDPOINT="${database_endpoint}"
DB_SECRET_ARN="${db_credentials_secret_arn}"
APP_SECRET_ARN="${app_credentials_secret_arn}"
S3_BUCKET="${s3_file_bucket}"
REDCAP_METHOD="${redcap_download_method}"
REDCAP_S3_BUCKET="${redcap_s3_bucket}"
REDCAP_S3_KEY="${redcap_s3_key}"
REDCAP_S3_REGION="${redcap_s3_bucket_region}"
REDCAP_VERSION="${redcap_version}"
CUSTOM_MODULES_S3_KEY="${custom_modules_s3_key}"
USE_ACM="${use_acm}"
USE_ROUTE53="${use_route53}"
DOMAIN_NAME="${domain_name}"
HOSTED_ZONE="${hosted_zone_name}"

# Logging setup
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "Starting REDCap installation at $(date)"

# Update system
dnf update -y

# Install required packages
dnf install -y \
    wget \
    unzip \
    mariadb105 \
    jq \
    amazon-cloudwatch-agent \
    postfix \
    cyrus-sasl-plain \
    cronie

# SSM Agent is pre-installed on AL2023; ensure it's running
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Configure timezone
timedatectl set-timezone UTC

# Install Nginx
dnf install -y nginx
systemctl enable nginx
# nginx is started after redcap.conf is written below
rm -f /etc/nginx/conf.d/default.conf

# Install PHP and required extensions
# AL2023 ships PHP 8.1 in its default repos
dnf install -y \
    php \
    php-fpm \
    php-mysqlnd \
    php-gd \
    php-ldap \
    php-zip \
    php-curl \
    php-mbstring \
    php-xml \
    php-json \
    php-openssl \
    php-devel \
    php-pear \
    gcc \
    ImageMagick \
    ImageMagick-devel

# Start PHP-FPM
systemctl enable php-fpm
systemctl start php-fpm

# Install PHP Imagick extension via PECL (not in AL2023 default repos)
# Required for inline PDF attachments in REDCap PDF exports
printf '\n' | pecl install imagick
echo "extension=imagick.so" > /etc/php.d/20-imagick.ini

# Fetch secrets from Secrets Manager (instance role provides access)
get_secret() {
    aws secretsmanager get-secret-value \
        --secret-id "$1" \
        --region "$AWS_REGION" \
        --query SecretString \
        --output text
}

echo "Fetching database credentials from Secrets Manager..."
DB_SECRET=$(get_secret "$DB_SECRET_ARN")
DB_PASSWORD=$(echo "$DB_SECRET" | jq -r '.master_password')
DB_REDCAP_USER_PASSWORD=$(echo "$DB_SECRET" | jq -r '.redcap_user_password')

echo "Fetching application credentials from Secrets Manager..."
APP_SECRET=$(get_secret "$APP_SECRET_ARN")
SENDGRID_API_KEY=$(echo "$APP_SECRET" | jq -r '.sendgrid_api_key')
REDCAP_USERNAME=$(echo "$APP_SECRET" | jq -r '.redcap_community_username')
REDCAP_PASSWORD=$(echo "$APP_SECRET" | jq -r '.redcap_community_password')
AMAZON_S3_KEY=$(echo "$APP_SECRET" | jq -r '.amazon_s3_key')
AMAZON_S3_SECRET=$(echo "$APP_SECRET" | jq -r '.amazon_s3_secret')

# Configure PHP settings for REDCap (modify defaults in place, no appending)
sed -i 's/^max_execution_time = .*/max_execution_time = 1200/' /etc/php.ini
sed -i 's/^;max_input_vars = .*/max_input_vars = 2000000/' /etc/php.ini
sed -i 's/^memory_limit = .*/memory_limit = 512M/' /etc/php.ini
sed -i 's/^post_max_size = .*/post_max_size = 2500M/' /etc/php.ini
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 2500M/' /etc/php.ini
sed -i 's/^;date\.timezone =.*/date.timezone = "America\/New_York"/' /etc/php.ini
sed -i 's/^;session\.cookie_secure =.*/session.cookie_secure = on/' /etc/php.ini

# Configure PHP-FPM pool: run as nginx (consistent with web root ownership) and long-running requests
sed -i 's/^user = .*/user = nginx/'  /etc/php-fpm.d/www.conf
sed -i 's/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^request_terminate_timeout\s*=.*/request_terminate_timeout = 1200/' /etc/php-fpm.d/www.conf
grep -q '^request_terminate_timeout' /etc/php-fpm.d/www.conf || \
    echo 'request_terminate_timeout = 1200' >> /etc/php-fpm.d/www.conf

# Fix PHP session directory ownership (default is root:apache, but PHP-FPM runs as nginx)
chown -R nginx:nginx /var/lib/php/session

# Mount encrypted volume for logs
LOG_DEVICE="/dev/nvme1n1"
LOG_MOUNT="/var/log/nginx"

if [[ -b "$LOG_DEVICE" ]]; then
    mkfs -t ext4 "$LOG_DEVICE"
    mkdir -p /tmp/nginx_logs_backup
    cp -a "$LOG_MOUNT"/* /tmp/nginx_logs_backup/ 2>/dev/null || true
    mount "$LOG_DEVICE" "$LOG_MOUNT"
    cp -a /tmp/nginx_logs_backup/* "$LOG_MOUNT"/ 2>/dev/null || true
    rm -rf /tmp/nginx_logs_backup
    echo "$LOG_DEVICE $LOG_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# Configure Nginx for REDCap
# ALB handles SSL termination; nginx only serves HTTP on port 80
# AL2023 PHP-FPM socket is at /run/php-fpm/www.sock
cat > /etc/nginx/conf.d/redcap.conf << 'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;

    # Large upload/download support
    client_max_body_size 2500M;
    client_body_buffer_size 128M;
    client_header_timeout 1200;
    client_body_timeout 1200;
    keepalive_timeout 1200;

    # Security headers
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    # REDCap specific configuration
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_read_timeout 1200;
        fastcgi_send_timeout 1200;
        fastcgi_buffers 64 256k;
        fastcgi_buffer_size 256k;
        fastcgi_busy_buffers_size 512k;
    }

    # Deny access to sensitive files
    location ~ /\. {
        deny all;
    }

    location ~ ~$ {
        deny all;
    }

    # REDCap specific denies
    location ~* \.(log|txt)$ {
        deny all;
    }
}
EOF

# Start nginx now that redcap.conf is written
systemctl start nginx

# Create web directory with placeholder so ALB health checks return 200
# while REDCap installation is in progress. Once REDCap is installed,
# index.php takes priority over index.html per the nginx index directive.
mkdir -p /var/www/html
echo 'OK' > /var/www/html/index.html
chown -R nginx:nginx /var/www/html

# Download and install REDCap
cd /tmp

if [[ "$REDCAP_METHOD" == "api" ]]; then
    echo "Downloading REDCap via API..."
    curl -o redcap.zip -d "username=$REDCAP_USERNAME&password=$REDCAP_PASSWORD&version=$REDCAP_VERSION&install=1" \
         -X POST https://redcap.vumc.org/plugins/redcap_consortium/versions.php
    REDCAP_FILE="redcap.zip"
else
    echo "Downloading REDCap from S3..."
    aws s3 cp "s3://$REDCAP_S3_BUCKET/$REDCAP_S3_KEY" . --region "$REDCAP_S3_REGION"
    REDCAP_FILE=$(basename "$REDCAP_S3_KEY")
fi

# Extract REDCap
unzip -q "$REDCAP_FILE"

# REDCap package layout can vary by source/version.
# Copy whichever extracted directory contains the application.
REDCAP_SRC_DIR=""
if [[ -d "redcap" ]]; then
    REDCAP_SRC_DIR="redcap"
elif ls -d redcap_v*/redcap >/dev/null 2>&1; then
    REDCAP_SRC_DIR="$(ls -d redcap_v*/redcap | head -n 1)"
elif ls -d redcap_v* >/dev/null 2>&1; then
    REDCAP_SRC_DIR="$(ls -d redcap_v* | head -n 1)"
fi

if [[ -z "$REDCAP_SRC_DIR" ]]; then
    echo "ERROR: Unable to find extracted REDCap directory."
    exit 1
fi

cp -a "$${REDCAP_SRC_DIR}/." /var/www/html/
rm -f "$REDCAP_FILE"
rm -rf redcap redcap_v*

# Web root owned by root — PHP-FPM (nginx) can read but not write (HIPAA/security best practice)
chown -R root:root /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# Only these two directories need to be writable by the web server
mkdir -p /var/www/html/temp /var/www/html/modules
chown nginx:nginx /var/www/html/temp /var/www/html/modules
chmod 775 /var/www/html/temp /var/www/html/modules

# Deploy custom REDCap External Modules from S3 (optional)
if [[ -n "$CUSTOM_MODULES_S3_KEY" ]]; then
    echo "Deploying custom REDCap External Modules from S3..."
    aws s3 cp "s3://$S3_BUCKET/$CUSTOM_MODULES_S3_KEY" /tmp/custom-modules.zip --region "$AWS_REGION"
    unzip -qo /tmp/custom-modules.zip -d /tmp/custom-modules

    if [[ -d /tmp/custom-modules/modules ]]; then
        cp -a /tmp/custom-modules/modules/. /var/www/html/modules/
        chown -R nginx:nginx /var/www/html/modules
    fi

    rm -rf /tmp/custom-modules /tmp/custom-modules.zip
    echo "Custom REDCap External Modules deployed"
fi

# Configure database connection
# database.php lives at the web root (not in a redcap/ subdirectory)
cat > /var/www/html/database.php << EOF
<?php
\$hostname   = '$DB_ENDPOINT';
\$db         = 'redcap';
\$username   = 'redcap_user';
\$password   = '$DB_REDCAP_USER_PASSWORD';
\$salt       = '';

// Get or create salt from Parameter Store
\$salt_param = shell_exec("aws ssm get-parameter --name '/$NAME_PREFIX/redcap/salt' --with-decryption --query 'Parameter.Value' --output text --region $AWS_REGION 2>/dev/null");
if (empty(\$salt_param) || strpos(\$salt_param, 'ParameterNotFound') !== false) {
    \$salt = bin2hex(random_bytes(16));
    shell_exec("aws ssm put-parameter --name '/$NAME_PREFIX/redcap/salt' --type 'SecureString' --value '\$salt' --region $AWS_REGION");
} else {
    \$salt = trim(\$salt_param);
}
EOF

# Wait for database to be available
echo "Waiting for database to be available..."
until mysql -h "$DB_ENDPOINT" -u master -p"$DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; do
    echo "Database not ready, waiting..."
    sleep 10
done

# Create REDCap database users (ALTER USER ensures password is correct even on snapshot restores)
mysql -h "$DB_ENDPOINT" -u master -p"$DB_PASSWORD" -e "
CREATE USER IF NOT EXISTS 'redcap_user'@'%' IDENTIFIED BY '$DB_REDCAP_USER_PASSWORD';
ALTER USER 'redcap_user'@'%' IDENTIFIED BY '$DB_REDCAP_USER_PASSWORD';
GRANT SELECT, INSERT, UPDATE, DELETE ON redcap.* TO 'redcap_user'@'%';
CREATE USER IF NOT EXISTS 'redcap_user2'@'%' IDENTIFIED BY '$DB_REDCAP_USER_PASSWORD';
ALTER USER 'redcap_user2'@'%' IDENTIFIED BY '$DB_REDCAP_USER_PASSWORD';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, REFERENCES ON redcap.* TO 'redcap_user2'@'%';
FLUSH PRIVILEGES;
"

# Determine the canonical REDCap URL for this deployment
if [[ "$USE_ROUTE53" == "true" ]]; then
    if [[ "$USE_ACM" == "true" ]]; then
        REDCAP_URL="https://$DOMAIN_NAME.$HOSTED_ZONE"
    else
        REDCAP_URL="http://$DOMAIN_NAME.$HOSTED_ZONE"
    fi
else
    REDCAP_URL="http://localhost"
fi

# Install or upgrade REDCap database schema (runs on first instance, uses flock to avoid races)
LOCK_FILE="/tmp/redcap_install.lock"
(
    flock -n 9 || exit 1

    # Get current DB version (empty string if not installed)
    DB_VERSION=$(mysql -h "$DB_ENDPOINT" -u master -p"$DB_PASSWORD" redcap \
        -e "SELECT value FROM redcap_config WHERE field_name='redcap_version'" \
        --skip-column-names 2>/dev/null || echo "")

    # Wait for nginx to be ready before hitting install/upgrade pages
    sleep 30

    if [[ -z "$DB_VERSION" ]]; then
        echo "Fresh install: running REDCap database install..."

        curl -k -X POST "http://localhost/install.php" \
            -d "redcap_csrf_token=" \
            -d "superusers_only_create_project=0" \
            -d "superusers_only_move_to_prod=1" \
            -d "auto_report_stats=1" \
            -d "bioportal_api_token=" \
            -d "redcap_base_url=$REDCAP_URL/" \
            -d "enable_url_shortener=1" \
            -d "default_datetime_format=D/M/Y_12" \
            -d "default_number_format_decimal=," \
            -d "default_number_format_thousands_sep=." \
            -d "homepage_contact=REDCap Administrator" \
            -d "homepage_contact_email=admin@example.com" \
            -d "project_contact_name=REDCap Administrator" \
            -d "project_contact_email=admin@example.com" \
            -d "institution=Your Institution" \
            -d "site_org_type=Research Institution" \
            -o /tmp/install_output.html

        if grep -q "onclick='this.select()'" /tmp/install_output.html; then
            sed -n "/onclick='this.select()'/,/<\/textarea>/p" /tmp/install_output.html | \
            sed '1d;$d' > /tmp/redcap_install.sql
            mysql -h "$DB_ENDPOINT" -u master -p"$DB_PASSWORD" redcap < /tmp/redcap_install.sql
            echo "REDCap fresh install SQL executed"

            # Create admin user
            mysql -h "$DB_ENDPOINT" -u master -p"$DB_PASSWORD" redcap -e "
                UPDATE redcap_config SET value = 'table' WHERE field_name = 'auth_meth_global';
                INSERT IGNORE INTO redcap_user_information (username, user_email, user_firstname, user_lastname, super_user)
                VALUES ('redcap_admin', 'admin@example.com', 'REDCap', 'Administrator', '1');
                INSERT IGNORE INTO redcap_auth (username, password, legacy_hash, temp_pwd)
                VALUES ('redcap_admin', MD5('$DB_PASSWORD'), '1', '1');
            "
            # Set initial infrastructure config on fresh install
            mysql -h "$DB_ENDPOINT" -u master -p"$DB_PASSWORD" redcap -e "
                UPDATE redcap_config SET value = '$REDCAP_URL/' WHERE field_name = 'redcap_base_url';
                UPDATE redcap_config SET value = '2' WHERE field_name = 'edoc_storage_option';
                UPDATE redcap_config SET value = '$S3_BUCKET' WHERE field_name = 'amazon_s3_bucket';
                UPDATE redcap_config SET value = '$AMAZON_S3_KEY' WHERE field_name = 'amazon_s3_key';
                UPDATE redcap_config SET value = '$AMAZON_S3_SECRET' WHERE field_name = 'amazon_s3_secret';
                UPDATE redcap_config SET value = '$AWS_REGION' WHERE field_name = 'amazon_s3_endpoint';
                REPLACE INTO redcap_config (field_name, value) VALUES ('aws_quickstart', '1');
                REPLACE INTO redcap_config (field_name, value) VALUES ('redcap_updates_user', 'redcap_user2');
                REPLACE INTO redcap_config (field_name, value) VALUES ('redcap_updates_password', '$DB_REDCAP_USER_PASSWORD');
                REPLACE INTO redcap_config (field_name, value) VALUES ('redcap_updates_password_encrypted', '0');
            "
            echo "REDCap config updated (base_url=$REDCAP_URL/, S3=$S3_BUCKET)"
        fi
        rm -f /tmp/redcap_install.sql /tmp/install_output.html

    elif [[ "$DB_VERSION" != "$REDCAP_VERSION" ]]; then
        echo "Version mismatch: DB has $DB_VERSION, code is $REDCAP_VERSION — running upgrade..."

        curl -s "http://localhost/upgrade.php" -o /tmp/upgrade_page.html
        python3 - << 'PYEOF'
import re
with open('/tmp/upgrade_page.html') as f:
    html = f.read()
textareas = re.findall(r'<textarea[^>]*>(.*?)</textarea>', html, re.DOTALL)
if textareas:
    with open('/tmp/redcap_upgrade.sql', 'w') as f:
        f.write(textareas[0])
    print(f"Upgrade SQL extracted: {len(textareas[0])} bytes")
else:
    print("ERROR: No SQL found in upgrade page")
PYEOF

        if [[ -f /tmp/redcap_upgrade.sql ]]; then
            mysql -h "$DB_ENDPOINT" -u master -p"$DB_PASSWORD" redcap < /tmp/redcap_upgrade.sql
            echo "REDCap upgrade from $DB_VERSION to $REDCAP_VERSION completed"
        fi
        rm -f /tmp/upgrade_page.html /tmp/redcap_upgrade.sql
    else
        echo "REDCap database is already at version $REDCAP_VERSION"
    fi

) 9>"$LOCK_FILE"

# Configure email (Postfix with SendGrid SMTP relay)
cat > /etc/postfix/main.cf << EOF
compatibility_level = 2
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/libexec/postfix
data_directory = /var/lib/postfix
mail_owner = postfix
inet_interfaces = localhost
inet_protocols = all
mydestination = \$myhostname, localhost.\$mydomain, localhost
unknown_local_recipient_reject_code = 550
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
debug_peer_level = 2
debugger_command =
         PATH=/bin:/usr/bin:/usr/local/bin:/usr/X11R6/bin
         ddd \$daemon_directory/\$process_name \$process_id & sleep 5
sendmail_path = /usr/sbin/sendmail.postfix
newaliases_path = /usr/bin/newaliases.postfix
mailq_path = /usr/bin/mailq.postfix
setgid_group = postdrop
html_directory = no
manpage_directory = /usr/share/man

# SendGrid SMTP relay
relayhost = [smtp.sendgrid.net]:587
smtp_sasl_auth_enable = yes
smtp_sasl_security_options = noanonymous
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_use_tls = yes
smtp_tls_security_level = encrypt
smtp_tls_note_starttls_offer = yes
smtp_tls_CAfile = /etc/ssl/certs/ca-bundle.crt

# Allow large attachments (SendGrid limit is 30MB)
message_size_limit = 31457280
mailbox_size_limit = 0
EOF

# Configure SendGrid credentials
echo "[smtp.sendgrid.net]:587 apikey:$SENDGRID_API_KEY" > /etc/postfix/sasl_passwd
postmap hash:/etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd*

# Start and enable postfix
systemctl enable postfix
systemctl start postfix

# REDCap Cron Job (runs every minute)
echo "* * * * * /bin/php /var/www/html/cron.php > /dev/null" | crontab -
systemctl enable crond
systemctl start crond

# Install and configure CloudWatch agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << EOF
{
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/nginx/access.log",
                        "log_group_name": "/aws/ec2/$NAME_PREFIX/nginx/access",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/log/nginx/error.log",
                        "log_group_name": "/aws/ec2/$NAME_PREFIX/nginx/error",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/log/php-fpm/www-error.log",
                        "log_group_name": "/aws/ec2/$NAME_PREFIX/php-fpm/error",
                        "log_stream_name": "{instance_id}"
                    }
                ]
            }
        }
    },
    "metrics": {
        "namespace": "REDCap/EC2",
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "diskio": {
                "measurement": [
                    "io_time"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 60
            }
        }
    }
}
EOF

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# Restart services
systemctl restart nginx
systemctl restart php-fpm

# Create health check endpoint — ALB only routes traffic once this file exists.
# Placed here (after full install + service restart) so the instance stays
# out of the target group until REDCap is genuinely ready to serve requests.
cat > /var/www/html/health.php << 'HEALTHEOF'
<?php http_response_code(200); echo 'OK';
HEALTHEOF
chown root:root /var/www/html/health.php
chmod 644 /var/www/html/health.php

# Unset sensitive variables before creating the marker file
unset DB_PASSWORD DB_REDCAP_USER_PASSWORD SENDGRID_API_KEY REDCAP_USERNAME REDCAP_PASSWORD AMAZON_S3_KEY AMAZON_S3_SECRET
unset DB_SECRET APP_SECRET

# Create marker file to indicate installation is complete
touch /var/log/redcap-installation-complete

echo "REDCap installation completed at $(date)"
echo "Access REDCap at: $(if [[ "$USE_ROUTE53" == "true" ]]; then echo "https://$DOMAIN_NAME.$HOSTED_ZONE"; else echo "http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"; fi)"
echo "Default admin user: redcap_admin (change password immediately after first login)"
