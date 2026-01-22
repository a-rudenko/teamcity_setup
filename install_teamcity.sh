#!/bin/bash

set -e

# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================
TEAMCITY_VERSION="2024.11.2"
POSTGRESQL_VERSION="18"
readonly DEFAULT_DB_NAME="teamcity"
readonly DEFAULT_DB_USER="teamcity"
# ============================================================================

NONE=$(tput sgr0)
TEXT_BOLD=$(tput bold)
BG_RED=$(tput setab 1)
GREEN=$(tput setaf 2)

if [ "$EUID" -ne 0 ]; then
  echo "Please run the script with sudo privileges"
  exit 1
fi

log_message() {
  echo "${GREEN}[INFO]${NONE} $1"
}

error_message() {
  echo "${BG_RED}${TEXT_BOLD}[ERROR] $1${NONE}"
}

command_not_found_handle() {
  if [ -x /usr/lib/command-not-found ]; then
    error_message "COMMAND NOT FOUND - $1"
  fi
}

# ============================================================================
# JAVA
# ============================================================================

read -p "Check Java version? [y/n] " answer
answer=${answer:-n}
if [[ $answer =~ ^[Yy]$ ]]; then
  if command -v java &>/dev/null; then
    java -version 2>&1 | head -1
  else
    echo "Java is not installed"
  fi
fi

read -p "Do you want to install openjdk-21-jdk? [y/n] " answer
answer=${answer:-n}
if [[ $answer =~ ^[Yy]$ ]]; then
  log_message "Updating packages..."
  apt update -q

  log_message "Installing openjdk-21-jdk..."
  apt install -y openjdk-21-jdk

  echo "Installed Java version:"
  java -version
fi

# ============================================================================
# POSTGRESQL
# ============================================================================

read -p "Check PostgreSQL installation? [y/n] " answer
if [[ ${answer:-n} =~ ^[Yy]$ ]]; then
  echo -n "PostgreSQL: "
  if command -v psql >/dev/null 2>&1; then
    echo "v$(psql --version | awk '{print $3}')"
    if systemctl is-active --quiet postgresql 2>/dev/null ||
      pgrep postgres >/dev/null 2>&1; then
      echo "  Service: running"
    fi
  else
    echo "PostgreSQL is not installed"
  fi
fi

read -p "Do you want to install PostgreSQL? [y/n] " answer
answer=${answer:-n}
if [[ $answer =~ ^[Yy]$ ]]; then
  echo "Available options:"
  echo "1) Install from Ubuntu repository"
  echo "2) Install PostgreSQL ${POSTGRESQL_VERSION} from official PostgreSQL repository"
  read -p "Choose option [1/2]: " install_option

  if [[ "$install_option" == "2" ]]; then
    log_message "Installing PostgreSQL ${POSTGRESQL_VERSION}..."

    wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc |
      sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" |
      sudo tee /etc/apt/sources.list.d/pgdg.list

    apt update -q
    apt install -y "postgresql-${POSTGRESQL_VERSION}" "postgresql-contrib-${POSTGRESQL_VERSION}"

    pg_version="${POSTGRESQL_VERSION}"
  else
    log_message "Installing PostgreSQL from Ubuntu repository..."

    apt update -q
    apt install -y postgresql postgresql-contrib

    pg_version=$(psql --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)
    if [ -z "$pg_version" ]; then
      pg_version=$(ls /etc/postgresql/ 2>/dev/null | head -1)
    fi
  fi

  log_message "Starting PostgreSQL ${pg_version}..."
  systemctl start postgresql@${pg_version}-main
  systemctl enable postgresql@${pg_version}-main

  log_message "PostgreSQL Status:"
  systemctl status postgresql@${pg_version}-main --no-pager
fi

read -p "Do you want to create a database and user for TeamCity in PostgreSQL? [y/n] " answer
answer=${answer:-n}
if [[ $answer =~ ^[Yy]$ ]]; then
  read -e -p "Database name [${DEFAULT_DB_NAME}]: " -i "${DEFAULT_DB_NAME}" db_name
  read -e -p "Username [${DEFAULT_DB_USER}]: " -i "${DEFAULT_DB_USER}" user

  password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
  echo "╔═════════════════════════════════════════╗"
  echo "║           SAVE THIS PASSWORD!           ║"
  echo "╚═════════════════════════════════════════╝"
  echo "Generated password: $password"

  log_message "Creating a database and user..."

  sudo -u postgres /usr/bin/psql <<EOT
    DROP USER IF EXISTS "$user";
    CREATE USER "$user" WITH PASSWORD '$password';
    DROP DATABASE IF EXISTS "$db_name";
    CREATE DATABASE "$db_name" OWNER "$user" ENCODING 'UTF8' LC_COLLATE='en_US.UTF-8' LC_CTYPE='en_US.UTF-8' TEMPLATE template0;
    GRANT ALL PRIVILEGES ON DATABASE "$db_name" TO "$user";
    ALTER USER "$user" WITH CREATEDB;
EOT

  PG_CONF="/etc/postgresql/$(ls /etc/postgresql | head -1)/main/pg_hba.conf"
  if [ -f "$PG_CONF" ]; then
    echo "Configuring PostgreSQL access rules..."
    echo "" >>"$PG_CONF"
    echo "# TeamCity connection" >>"$PG_CONF"
    echo "host    $db_name    $user    127.0.0.1/32    scram-sha-256" >>"$PG_CONF"
    echo "host    $db_name    $user    ::1/128         scram-sha-256" >>"$PG_CONF"

    POSTGRESQL_VERSION=$(ls /etc/postgresql/ | sort -V | head -1)
    /usr/bin/pg_ctlcluster "$POSTGRESQL_VERSION" main reload
  else
    echo "Warning: pg_hba.conf not found at $PG_CONF"
  fi

  log_message "Database '$db_name' and user '$user' created successfully"
  echo "Connection parameters for TeamCity:"
  echo "  Database: $db_name"
  echo "  Username: $user"
  echo "  Password: $password"
fi

# ============================================================================
# TEAMCITY
# ============================================================================

read -p "Do you want to install TeamCity? [y/n] " answer
answer=${answer:-n}
if [[ $answer =~ ^[Yy]$ ]]; then
  local_archives=($(ls TeamCity-*.tar.gz 2>/dev/null))
  if [ ${#local_archives[@]} -eq 0 ]; then
    log_error "The TeamCity local archive was not found in the current directory"
    log_info "Please download the TeamCity archive manually or use the online installation"

    read -p "Do you want to download TeamCity from the official website? [y/n] " download_answer
    download_answer=${download_answer:-n}

    if [[ $download_answer =~ ^[Yy]$ ]]; then
      TEAMCITY_URL="https://download.jetbrains.com/teamcity/TeamCity-${TEAMCITY_VERSION}.tar.gz"

      log_message "Downloading TeamCity ${TEAMCITY_VERSION}..."
      if ! wget -q --show-progress "$TEAMCITY_URL" -O "/tmp/TeamCity-${TEAMCITY_VERSION}.tar.gz"; then
        error_message "Error downloading TeamCity"
        exit 1
      fi

      ARCHIVE_PATH="/tmp/TeamCity-${TEAMCITY_VERSION}.tar.gz"
      TEAMCITY_VERSION="${TEAMCITY_VERSION}"
    else
      log_info "Installation interrupted. Download the TeamCity archive and place it in the current directory"
      exit 0
    fi
  else
    ARCHIVE_PATH="./${local_archives[0]}"
    if [[ "${local_archives[0]}" =~ TeamCity-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz ]]; then
      TEAMCITY_VERSION="${BASH_REMATCH[1]}"
      log_message "Local TeamCity archive found - ${TEAMCITY_VERSION}"
    else
      TEAMCITY_VERSION="custom"
      log_message "TeamCity local archive found (unknown version)"
    fi

    log_message "Checking archive integrity..."
    if ! tar -tzf "$ARCHIVE_PATH" >/dev/null 2>&1; then
      error_message "The archive is corrupted or has an invalid format"
      exit 1
    fi
  fi

  log_message "Unpacking TeamCity ${TEAMCITY_VERSION}..."
  TEMP_DIR=$(mktemp -d)

  if ! tar -xzf "$ARCHIVE_PATH" -C "$TEMP_DIR"; then
    error_message "Error unpacking archive"
    rm -rf "$TEMP_DIR"
    exit 1
  fi

  if [ ! -d "$TEMP_DIR/TeamCity" ]; then
    error_message "The archive does not contain the TeamCity directory"
    rm -rf "$TEMP_DIR"
    exit 1
  fi

  mkdir -p /opt/JetBrains
  if [ -d "/opt/JetBrains/TeamCity" ]; then
    BACKUP_DIR="/opt/JetBrains/TeamCity.backup_$(date +%Y%m%d_%H%M%S)"
    log_message "Creating a backup copy of an existing TeamCity installation: $BACKUP_DIR"
    mv "/opt/JetBrains/TeamCity" "$BACKUP_DIR"
  fi

  mv "$TEMP_DIR/TeamCity" "/opt/JetBrains/TeamCity"
  rm -rf "$TEMP_DIR"

  echo "Installing PostgreSQL JDBC driver..."
  if apt install -y libpostgresql-jdbc-java 2>/dev/null; then
    JDBC_FILE=$(find /usr/share/java -name "postgresql.jar" 2>/dev/null | head -1)
    if [ -n "$JDBC_FILE" ]; then
      mkdir -p /opt/JetBrains/TeamCity/lib
      mkdir -p /opt/JetBrains/TeamCity/webapps/ROOT/WEB-INF/lib 2>/dev/null

      cp "$JDBC_FILE" /opt/JetBrains/TeamCity/lib/
      cp "$JDBC_FILE" /opt/JetBrains/TeamCity/webapps/ROOT/WEB-INF/lib/ 2>/dev/null

      echo "✓ The JDBC driver is installed"
    fi
  else
    echo "⚠ Failed to install via apt"
    echo "Install manually if there is an error connecting to the database"
  fi

  mkdir -p /var/teamcity
  chown -R $SUDO_USER:$SUDO_USER /opt/JetBrains/TeamCity /var/teamcity
  export TEAMCITY_DATA_PATH="/var/teamcity"
  log_message "Creating a systemd service..."

  cat >/etc/systemd/system/teamcity.service <<EOF
[Unit]
Description=TeamCity Server
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=forking
User=$SUDO_USER
Group=$SUDO_USER
Environment="TEAMCITY_DATA_PATH=/var/teamcity"
Environment="TEAMCITY_SERVER_MEM_OPTS=-Xmx2g -XX:ReservedCodeCacheSize=512m"
WorkingDirectory=/opt/JetBrains/TeamCity
ExecStart=/opt/JetBrains/TeamCity/bin/runAll.sh start
ExecStop=/opt/JetBrains/TeamCity/bin/runAll.sh stop
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/teamcity.service

  systemctl daemon-reload
  systemctl enable teamcity.service

  log_message "Launching TeamCity..."
  if systemctl start teamcity.service; then
    log_message "eamCity has been launched successfully"
    systemctl status teamcity.service --no-pager
  else
    error_message "TeamCity launch error"
    journalctl -u teamcity.service -n 50 --no-pager
  fi

  if [[ "$ARCHIVE_PATH" == /tmp/TeamCity-* ]]; then
    rm -f "$ARCHIVE_PATH"
  fi

  log_message "TeamCity ${TEAMCITY_VERSION} is installed in /opt/JetBrains/TeamCity"
  log_message "Data is stored in /var/teamcity"
  log_message "The service is controlled by the command: sudo systemctl [start|stop|restart|status] teamcity"
fi

# ============================================================================
# NGINX
# ============================================================================

read -p "Do you want to install nginx (to proxy TeamCity to port 80)? [y/n] " answer
answer=${answer:-n}
if [[ $answer =~ ^[Yy]$ ]]; then
  log_message "Installing nginx..."
  apt update -q
  apt install -y nginx

  read -e -p "Server name (domain or IP) [localhost]: " -i "localhost" server_name
  server_name=${server_name:-localhost}

  cat >/etc/nginx/sites-available/teamcity <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $server_name;

    access_log /var/log/nginx/teamcity.access.log;
    error_log /var/log/nginx/teamcity.error.log;

    proxy_connect_timeout       600;
    proxy_send_timeout          600;
    proxy_read_timeout          600;
    send_timeout                600;
    client_max_body_size        256M;

    location / {
        proxy_pass          http://127.0.0.1:8111;
        proxy_http_version  1.1;
        proxy_set_header    Host               \$host;
        proxy_set_header    X-Real-IP          \$remote_addr;
        proxy_set_header    X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto  \$scheme;
        proxy_set_header    X-Forwarded-Host   \$host;
        proxy_set_header    X-Forwarded-Port   \$server_port;
        proxy_set_header    Upgrade            \$http_upgrade;
        proxy_set_header    Connection         \$connection_upgrade;

        proxy_set_header    Sec-WebSocket-Extensions \$http_sec_websocket_extensions;
        proxy_set_header    Sec-WebSocket-Key      \$http_sec_websocket_key;
        proxy_set_header    Sec-WebSocket-Version  \$http_sec_websocket_version;

        proxy_buffering off;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    location ~* ^/img/|^/css/|^/js/|^/fonts/ {
        proxy_pass          http://127.0.0.1:8111;
        proxy_http_version  1.1;
        proxy_set_header    Host \$host;
        expires             30d;
        add_header          Cache-Control "public, immutable";
    }
}
EOF

  ln -sf /etc/nginx/sites-available/teamcity /etc/nginx/sites-enabled/
  if [ -f /etc/nginx/sites-enabled/default ]; then
    rm /etc/nginx/sites-enabled/default
  fi

  log_message "Checking nginx configuration..."
  if nginx -t; then
    systemctl restart nginx
    systemctl enable nginx
    log_message "nginx is successfully configured and running"
  else
    error_message "Error in nginx configuration"
    exit 1
  fi
fi

# ============================================================================
# LETSENCRYPT
# ============================================================================

read -p "Do you want to activate TSL with LetsEncrypt? [y/n] " answer
answer=${answer:-n}
if [[ $answer =~ ^[Yy]$ ]]; then
  if ! systemctl is-active --quiet nginx; then
    error_message "nginx is not running. First, install and configure nginx"
    exit 1
  fi

  log_message "Installing certbot..."
  apt update -q
  apt install -y certbot python3-certbot-nginx

  read -p "LetsEncrypt registration email (required): " email
  if [ -z "$email" ]; then
    error_message "Email is required for LetsEncrypt registration"
    exit 1
  fi

  read -e -p "Domain name (must point to this server): " server_name
  if [ -z "$server_name" ] || [ "$server_name" == "localhost" ]; then
    error_message "TSL requires a real domain, not localhost"
    exit 1
  fi

  log_message "Obtaining an TSL certificate for $server_name..."
  if certbot --nginx -d "$server_name" --non-interactive --agree-tos --email "$email" --redirect; then
    log_message "TSL is successfully configured!"
    certbot renew --dry-run
    (
      crontab -l 2>/dev/null
      echo "0 12 * * * /usr/bin/certbot renew --quiet"
    ) | crontab -
    log_message "The certificate will be renewed automatically"
  else
    error_message "Error obtaining TSL certificate"
  fi
fi

echo
echo "==============================================="
echo "Installation complete!"
echo

if systemctl is-active --quiet teamcity; then
  echo "TeamCity is launched and available at:"
  echo "  - http://localhost:8111 (direct access)"

  if systemctl is-active --quiet nginx; then
    if [[ "$server_name" == "localhost" ]]; then
      echo "  - http://localhost"
    else
      echo "  - http://$server_name"
      if [ -f /etc/letsencrypt/live/$server_name/fullchain.pem ]; then
        echo "  - https://$server_name"
      fi
    fi
  fi
else
  echo "TeamCity is not running. Start it with the following command:"
  echo "  sudo systemctl start teamcity"
fi

echo
echo "To initially configure TeamCity:"
echo "1. Open the web interface"
echo "2. Accept the license agreement"
echo "3. Select PostgreSQL as the database"
echo "4. Use the connection parameters specified above"
echo "==============================================="
