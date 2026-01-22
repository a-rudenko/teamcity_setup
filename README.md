# Setup TeamCity on Ubuntu

#### Description

This bash script automates the installation and configuration of a complete TeamCity CI/CD stack on Ubuntu-compatible systems. The script installs all necessary components for running TeamCity.

[System Requirements](https://www.jetbrains.com/help/teamcity/system-requirements.html)

#### Features

* Java - OpenJDK 21 installation
* PostgreSQL - Relational database installation (Ubuntu or official repository)
* TeamCity Server - TeamCity installation (Latest from JetBrains or custom version)
* Nginx - Reverse proxy configuration on port 80/443
* Let's Encrypt - Automatic TSL certificate setup
* Systemd Service - TeamCity auto-start as a service
* PostgreSQL JDBC Driver - Automatic driver installation
* Interactive Setup - Step-by-step configuration with user prompts
* Uninstall script - For testing purposes

#### Quick Start

Before installation, you can override the version of TeamCity and Postgres in the script's settings:

```
# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================
TEAMCITY_VERSION="CUSTOM_VERSION"
POSTGRESQL_VERSION="CUSTOM_VERSION"
...
# ============================================================================
```

1. Make it executable `chmod +x install_teamcity.sh`
2. Run with sudo `sudo ./install_teamcity.sh`

#### Accessing TeamCity

After installation, TeamCity is available at:

* Direct access: http://localhost:8111
* Via Nginx (if installed): http://your-domain.com or http://localhost
* HTTPS (if Let's Encrypt configured): https://your-domain.com

#### Initial Setup

1. Open TeamCity in your browser
2. Accept license agreement
3. Database Configuration:
   * Select PostgreSQL
   * Host: 127.0.0.1
   * Port: 5432
   * Database: teamcity
   * Username: teamcity
   * Password: (use the generated password from installation)
4. Configure administrator account
5. Start using TeamCity

#### Post-Installation Checklist

* Verify TeamCity service is running: sudo systemctl status teamcity
* Test web interface access
* Save PostgreSQL credentials in a secure location
* Configure backup strategy for /var/teamcity
* Set up regular PostgreSQL backups
* Configure firewall rules if needed
* Monitor disk space for build artifacts

#### Logs Location

* TeamCity logs: /var/teamcity/logs/
* Systemd logs: sudo journalctl -u teamcity
* Nginx logs: /var/log/nginx/teamcity.*.log
* PostgreSQL logs: /var/log/postgresql/postgresql-*.log

#### Uninstallation

Use the included uninstallation script to remove all components:

Dry run (show what would be removed):

```
sudo ./uninstall_teamcity.sh --dry-run
```

Interactive removal (asks for confirmation):

```
sudo ./uninstall_teamcity.sh
```

Force removal (no confirmation):

```
sudo ./uninstall_teamcity.sh --force
```
