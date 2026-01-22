<h1 align="center">Setup TeamCity on Ubuntu</h1>

This bash script automates the installation and configuration of a complete TeamCity CI/CD stack on Ubuntu-compatible systems. The script installs all necessary components for running TeamCity.

[System Requirements](https://www.jetbrains.com/help/teamcity/system-requirements.html)

<h2>Features</h2> 

* Java - OpenJDK 21 installation
* PostgreSQL - Relational database installation (Ubuntu or official repository)
* TeamCity Server - TeamCity installation (Latest from JetBrains or custom version)
* Nginx - Reverse proxy configuration on port 80/443
* Let's Encrypt - Automatic TSL certificate setup
* Systemd Service - TeamCity auto-start as a service
* PostgreSQL JDBC Driver - Automatic driver installation
* Interactive Setup - Step-by-step configuration with user prompts
* Uninstall script - For testing purposes

<h2>Quick Start</h2> 

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

1&#46; Make it executable 

```
chmod +x install_teamcity.sh
```

2&#46; Run with sudo

```
sudo ./install_teamcity.sh
```

<h2>Accessing TeamCity</h2>

After installation, TeamCity is available at:

* Direct access: http://localhost:8111
* Via Nginx (if installed): http://your-domain.com or http://localhost
* HTTPS (if Let's Encrypt configured): https://your-domain.com

<h2>Initial Setup</h2>

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

<h2>Post-Installation Checklist</h2>

* Verify TeamCity service is running: sudo systemctl status teamcity
* Test web interface access
* Save PostgreSQL credentials in a secure location
* Configure backup strategy for /var/teamcity
* Set up regular PostgreSQL backups
* Configure firewall rules if needed
* Monitor disk space for build artifacts

<h2>Logs Location</h2>

* TeamCity logs: /var/teamcity/logs/
* Systemd logs: sudo journalctl -u teamcity
* Nginx logs: /var/log/nginx/teamcity.*.log
* PostgreSQL logs: /var/log/postgresql/postgresql-*.log

<h2>Uninstallation</h2>

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

<h2>License</h2>

<a href="https://github.com/a-rudenko/teamcity_setup/blob/master/LICENSE">MIT</a>
