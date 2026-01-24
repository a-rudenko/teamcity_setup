#!/bin/bash

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================
readonly DEFAULT_DB_NAME="teamcity"
readonly DEFAULT_DB_USER="teamcity"
readonly TEAMCITY_INSTALL_DIR="/opt/JetBrains/TeamCity"
readonly TEAMCITY_DATA_DIR="/var/teamcity"
# ============================================================================

NONE=$(tput sgr0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BG_RED=$(tput setab 1)
TEXT_BOLD=$(tput bold)

AUTO_CONFIRM=false

if [ "$EUID" -ne 0 ]; then
  echo "${RED}${TEXT_BOLD}Please run the script with sudo privileges${NONE}"
  exit 1
fi

log_message() {
  echo "${GREEN}[INFO]${NONE} $1"
}

log_warn() {
  echo "${YELLOW}[WARN]${NONE} $1"
}

log_error() {
  echo "${BG_RED}${TEXT_BOLD}[ERROR] $1${NONE}"
}

confirm_action() {
  local prompt="$1"
  local default="${2:-n}"

  if [ "$AUTO_CONFIRM" = true ]; then
    log_message "Auto-confirmed: $prompt"
    return 0
  fi

  read -rp "$prompt [y/n] " answer
  answer="${answer:-$default}"

  [[ $answer =~ ^[Yy]$ ]]
}

# ============================================================================
# REMOVAL FUNCTIONS
# ============================================================================
remove_teamcity_service() {
  log_message "Removing TeamCity service..."

  if [ ! -f /etc/systemd/system/teamcity.service ] &&
    ! systemctl list-unit-files | grep -q teamcity.service 2>/dev/null; then
    log_message "TeamCity service not found, skipping"
    return 0
  fi

  if systemctl is-active --quiet teamcity.service 2>/dev/null; then
    systemctl stop teamcity.service
  fi

  if systemctl is-enabled --quiet teamcity.service 2>/dev/null; then
    systemctl disable teamcity.service
  fi

  rm -f /etc/systemd/system/teamcity.service
  systemctl daemon-reload
  systemctl reset-failed
}

remove_teamcity_files() {
  log_message "Removing TeamCity files..."

  if [ -d "$TEAMCITY_DATA_DIR" ] && [ "$AUTO_CONFIRM" = false ]; then
    echo "${YELLOW}Warning: All TeamCity data in $TEAMCITY_DATA_DIR will be deleted${NONE}"
    echo "Data includes: projects, builds, users, configurations"
    echo
  fi

  local errors=0

  if [ -d "$TEAMCITY_INSTALL_DIR" ]; then
    if rm -rf "$TEAMCITY_INSTALL_DIR"; then
      log_message "✓ Removed: $TEAMCITY_INSTALL_DIR"
    else
      log_warn "Failed to remove: $TEAMCITY_INSTALL_DIR"
      ((errors++))
    fi
  fi

  if [ -d "$TEAMCITY_DATA_DIR" ]; then
    if rm -rf "$TEAMCITY_DATA_DIR"; then
      log_message "✓ Removed: $TEAMCITY_DATA_DIR"
    else
      log_warn "Failed to remove: $TEAMCITY_DATA_DIR"
      ((errors++))
    fi
  fi

  if rm -rf /opt/JetBrains/TeamCity.backup_* 2>/dev/null; then
    log_message "✓ Removed backup directories"
  fi

  if rm -f /tmp/TeamCity-*.tar.gz 2>/dev/null; then
    log_message "✓ Removed temporary files"
  fi

  if [ $errors -eq 0 ]; then
    log_message "✓ All TeamCity files removed successfully"
  else
    log_warn "Some files could not be removed ($errors errors)"
  fi
}

remove_postgresql_db() {
  if confirm_action "Remove TeamCity PostgreSQL database and user?" "n"; then
    if ! command -v psql >/dev/null 2>&1; then
      log_warn "PostgreSQL client not found"
      return
    fi

    if ! sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
      log_warn "Cannot connect to PostgreSQL server"
      return
    fi

    log_message "Removing PostgreSQL database and user..."

    read -re -p "Database name [${DEFAULT_DB_NAME}]: " -i "${DEFAULT_DB_NAME}" db_name
    read -re -p "Username [${DEFAULT_DB_USER}]: " -i "${DEFAULT_DB_USER}" user

    sudo -u postgres psql <<EOT 2>/dev/null || true
      DROP DATABASE IF EXISTS "$db_name";
      DROP USER IF EXISTS "$user";
EOT

    local pg_conf_dir="/etc/postgresql"
    if [ -d "$pg_conf_dir" ]; then
      local pg_version
      pg_version=$(find "$pg_conf_dir" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | head -1)
      local pg_conf="$pg_conf_dir/$pg_version/main/pg_hba.conf"

      if [ -f "$pg_conf" ]; then
        sed -i "/^host[[:space:]]\+${db_name}[[:space:]]\+$user/d" "$pg_conf" 2>/dev/null || true
        log_message "Removed rules from pg_hba.conf"

        if systemctl is-active --quiet "postgresql@${pg_version}-main" 2>/dev/null; then
          systemctl reload "postgresql@${pg_version}-main"
        fi
      fi
    fi
  fi
}

remove_postgresql_server() {
  if ! command -v psql >/dev/null 2>&1 && [ ! -d /etc/postgresql ]; then
    echo "PostgreSQL is not installed"
    return 0
  fi

  local version
  version=$(psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
  if [ -n "$version" ]; then
    echo "Found PostgreSQL version: $version"
  fi

  if confirm_action "Remove PostgreSQL server packages?" "n"; then
    systemctl stop postgresql* 2>/dev/null || true
    systemctl disable postgresql* 2>/dev/null || true

    apt remove --purge -y postgresql\* 2>/dev/null || true
    dpkg -l | grep postgres | awk '{print $2}' | xargs dpkg --purge --force-all 2>/dev/null || true

    echo "Cleaning up PostgreSQL files..."
    rm -rf /var/lib/postgresql /etc/postgresql* 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/pgdg* /usr/share/keyrings/postgresql* 2>/dev/null || true

    echo "Cleaning up dependencies..."
    apt autoremove -y 2>/dev/null || true

    log_message "✓ PostgreSQL removal completed"
  else
    echo "PostgreSQL removal cancelled"
  fi
}

remove_nginx_config() {
  log_message "Removing nginx configuration..."
  local errors=0

  if rm -f /etc/nginx/sites-enabled/teamcity 2>/dev/null; then
    log_message "✓ Removed nginx site link"
  else
    ((errors++))
  fi

  if [ -f /etc/nginx/sites-available/teamcity ]; then
    if rm -f /etc/nginx/sites-available/teamcity; then
      log_message "✓ Removed: /etc/nginx/sites-available/teamcity"
    else
      log_warn "Failed to remove nginx configuration"
      ((errors++))
    fi
  fi

  if [ ! -f /etc/nginx/sites-enabled/default ] && [ -f /etc/nginx/sites-available/default ]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
    log_message "✓ Restored default nginx site"
  fi

  if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx
  fi

  if [ $errors -eq 0 ]; then
    log_message "✓ nginx configuration removed"
  fi
}

remove_letsencrypt() {
  if confirm_action "Remove Let's Encrypt TSL certificates?" "n"; then
    log_message "Removing Let's Encrypt certificates..."

    read -re -p "Domain name: " domain_name
    if [ -n "$domain_name" ]; then
      if certbot revoke --cert-name "$domain_name" --delete-after-revoke 2>/dev/null; then
        log_message "✓ Certificate revoked: $domain_name"
      else
        log_warn "Failed to revoke certificate: $domain_name"
      fi

      if [ -f /etc/nginx/sites-available/teamcity ]; then
        sed -i "/# managed by Certbot/,+1d" /etc/nginx/sites-available/teamcity 2>/dev/null || true
        sed -i "/ssl_/d" /etc/nginx/sites-available/teamcity 2>/dev/null || true
        sed -i "s/listen 443 ssl/listen 80/" /etc/nginx/sites-available/teamcity 2>/dev/null || true
      fi
    fi

    if crontab -l 2>/dev/null | grep -v "certbot renew" | crontab - 2>/dev/null; then
      log_message "✓ Removed certbot cron job"
    fi
  fi
}

remove_packages_safely() {
  log_message "Checking installed packages..."

  if dpkg -l | grep -q libpostgresql-jdbc-java; then
    if confirm_action "Remove PostgreSQL JDBC driver?" "n"; then
      if apt remove -y libpostgresql-jdbc-java 2>/dev/null; then
        log_message "✓ JDBC driver removed"
      else
        local exit_code=$?
        log_warn "Failed to remove JDBC driver (exit code: $exit_code)"
        if [ $exit_code -eq 100 ]; then
          log_warn "Package not found or already removed"
        fi
      fi
    fi
  fi

  if dpkg -l | grep -q openjdk-21-jdk; then
    if confirm_action "Remove Java (openjdk-21-jdk)?" "n"; then
      if apt remove -y openjdk-21-jdk 2>/dev/null; then
        log_message "✓ Java removed"
      else
        local exit_code=$?
        log_warn "Failed to remove Java (exit code: $exit_code)"
      fi
    fi
  fi

  remove_postgresql_server

  if dpkg -l | grep -q nginx; then
    if confirm_action "Remove nginx?" "n"; then
      systemctl stop nginx 2>/dev/null || true
      if apt remove -y nginx 2>/dev/null; then
        log_message "✓ nginx removed"
      else
        local exit_code=$?
        log_warn "Failed to remove nginx (exit code: $exit_code)"
      fi
    fi
  fi

  if dpkg -l | grep -q certbot; then
    if confirm_action "Remove certbot?" "n"; then
      if apt remove -y certbot python3-certbot-nginx 2>/dev/null; then
        log_message "✓ certbot removed"
      else
        local exit_code=$?
        log_warn "Failed to remove certbot (exit code: $exit_code)"
      fi
    fi
  fi

  if apt autoremove -y 2>/dev/null; then
    log_message "✓ Removed unused dependencies"
  fi

  if apt clean 2>/dev/null; then
    log_message "✓ Cleaned package cache"
  fi
}

cleanup_logs_safely() {
  log_message "Cleaning up TeamCity logs..."

  if journalctl --unit=teamcity.service --vacuum-time=1d 2>/dev/null; then
    log_message "✓ Cleaned TeamCity service logs"
  fi

  if rm -f /var/log/teamcity*.log 2>/dev/null; then
    log_message "✓ Removed TeamCity log files"
  fi

  if rm -f /var/log/nginx/teamcity*.log 2>/dev/null; then
    log_message "✓ Removed nginx TeamCity logs"
  fi
}

check_remaining() {
  log_message "Checking for remaining components..."

  echo "1. TeamCity installation:"
  if [ -d "$TEAMCITY_INSTALL_DIR" ]; then
    echo "   ✓ $TEAMCITY_INSTALL_DIR"
  else
    echo "   ✗ Not found"
  fi

  echo
  echo "2. TeamCity data:"
  if [ -d "$TEAMCITY_DATA_DIR" ]; then
    echo "   ✓ $TEAMCITY_DATA_DIR"
  else
    echo "   ✗ Not found"
  fi

  echo
  echo "3. TeamCity service:"
  if systemctl list-unit-files 2>/dev/null | grep -q teamcity; then
    echo "   ✓ teamcity.service"
  else
    echo "   ✗ Not found"
  fi

  echo
  echo "4. nginx configuration:"
  if [ -f /etc/nginx/sites-available/teamcity ]; then
    echo "   ✓ /etc/nginx/sites-available/teamcity"
  else
    echo "   ✗ Not found"
  fi

  echo
  echo "5. PostgreSQL database:"
  if command -v psql >/dev/null 2>&1; then
    echo "   ✓ PostgreSQL is installed"
    if sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${DEFAULT_DB_NAME}"; then
      echo "   ✓ Database '${DEFAULT_DB_NAME}' exists"
    else
      echo "   ✗ Database '${DEFAULT_DB_NAME}' not found"
    fi
  else
    echo "   ✗ PostgreSQL not installed"
  fi

  echo
  echo "6. Let's Encrypt certificates:"
  if command -v certbot >/dev/null 2>&1; then
    echo "   ✓ certbot is installed"
    if [ -d /etc/letsencrypt/live ]; then
      echo "   ✓ SSL certificates directory exists"
    else
      echo "   ✗ SSL certificates directory not found"
    fi
  else
    echo "   ✗ certbot not installed"
  fi
}

# ============================================================================
# MAIN REMOVAL FUNCTION
# ============================================================================

main_removal() {
  echo "${TEXT_BOLD}================================================${NONE}"
  echo "${TEXT_BOLD}        TEAMCITY COMPLETE REMOVAL SCRIPT        ${NONE}"
  echo "${TEXT_BOLD}================================================${NONE}"
  echo
  echo "${YELLOW}${TEXT_BOLD}WARNING: This action cannot be undone!${NONE}"
  echo
  echo "The following will be removed:"
  echo "  • TeamCity server and all data"
  echo "  • TeamCity systemd service"
  echo "  • nginx configuration for TeamCity"
  echo "  • PostgreSQL database (optional)"
  echo "  • TSL certificates (optional)"
  echo "  • Installed packages (optional)"
  echo

  if ! confirm_action "Are you sure you want to continue?" "n"; then
    log_message "Removal cancelled"
    exit 0
  fi

  echo
  log_message "Starting removal process..."
  logger -t teamcity-removal "TeamCity removal started by $(whoami)"

  remove_teamcity_service
  remove_teamcity_files

  if [ -f /etc/nginx/sites-available/teamcity ]; then
    remove_nginx_config
  fi

  if command -v psql >/dev/null 2>&1; then
    remove_postgresql_db
  fi

  if command -v certbot >/dev/null 2>&1; then
    remove_letsencrypt
  fi

  remove_packages_safely
  cleanup_logs_safely
  check_remaining

  echo
  echo "${TEXT_BOLD}${GREEN}===============================================${NONE}"
  echo "${TEXT_BOLD}${GREEN}        REMOVAL COMPLETED SUCCESSFULLY!        ${NONE}"
  echo "${TEXT_BOLD}${GREEN}===============================================${NONE}"
  echo
  echo "${YELLOW}Note: All TeamCity data has been permanently deleted.${NONE}"
  echo "${YELLOW}Consider rebooting the system:${NONE}"
  echo "  sudo reboot"
}

# ============================================================================
# COMMAND LINE ARGUMENTS
# ============================================================================

case "${1:-}" in
--help | -h)
  echo "Usage: sudo $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  -h, --help     Show this help message"
  echo "  --dry-run      Show what would be removed without actually removing"
  echo "  --force        Force removal without prompts (use with caution!)"
  echo
  echo "Examples:"
  echo "  sudo $0           # Interactive removal (asks for confirmation)"
  echo "  sudo $0 --dry-run # Show what would be removed"
  echo "  sudo $0 --force   # Automatic removal (no questions)"
  exit 0
  ;;
--dry-run)
  echo "${TEXT_BOLD}==============================================${NONE}"
  echo "${TEXT_BOLD}          TEAMCITY REMOVAL - DRY RUN          ${NONE}"
  echo "${TEXT_BOLD}==============================================${NONE}"
  echo
  echo "${GREEN}Checking what would be removed (no actual deletion)${NONE}"
  echo
  check_remaining
  exit 0
  ;;
--force)
  echo "${RED}${TEXT_BOLD}=================================================${NONE}"
  echo "${RED}${TEXT_BOLD}          FORCE REMOVAL MODE - WARNING!          ${NONE}"
  echo "${RED}${TEXT_BOLD}=================================================${NONE}"
  echo
  echo "${RED}All components will be removed WITHOUT confirmation!${NONE}"
  echo "${RED}No prompts, no warnings, immediate deletion.${NONE}"
  echo
  read -rp "Type 'YES' to continue: " confirm
  if [ "$confirm" != "YES" ]; then
    echo "Aborted"
    exit 1
  fi
  AUTO_CONFIRM=true
  ;;
esac

# ============================================================================
# EXECUTE
# ============================================================================

main_removal

logger -t teamcity-removal "TeamCity removal completed by $(whoami)"
