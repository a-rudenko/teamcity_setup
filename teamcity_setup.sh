#!/bin/bash

NONE=$(tput sgr0)
TEXT_BOLD=$(tput bold)
BG_RED=$(tput setab 1)

command_not_found_handle() {
  if [ -x /usr/lib/command-not-found ]; then
    echo ${BG_RED}${TEXT_BOLD}COMMAND NOT FOUND - $1${NONE}
  fi
}

#===================================Java
read -p "Check Java version? [y/n]" answer
if [ $answer == "y" ]; then
  echo "$(java -version)"
fi

read -p "Do you want to install openjdk-11-jdk? [y/n]" answer
if [ $answer == "y" ]; then
  apt update
  apt install openjdk-11-jdk
  java -version
fi

#===================================MySQL
read -p "Check MySQL version? [y/n]" answer
if [ $answer == "y" ]; then
  echo "${TEXT_BOLD}$(mysql -V)${NONE}"
fi

read -p "Do you want to install MySQL? [y/n]" answer
if [ $answer == "y" ]; then
  apt update
  apt install mysql-server
  mysql -V
  /etc/init.d/mysql stop
  mysqld --skip-grant-tables --user=root
  /etc/init.d/mysql restart
  read -s -p "New root password: " root_password
  echo
  mysql <<EOT
   ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$root_password';
   FLUSH PRIVILEGES;
EOT
  /etc/init.d/mysql restart
fi

read -p "Do you want to create user for TeamCity in MySQL? [y/n]" answer
if [ $answer == "y" ]; then
  read -e -p "Database name [teamcity]: " -i "teamcity" db_name
  read -e -p "Database user [teamcity]: " -i "teamcity" user
  read -s -p "Password for new user: " password
  echo
  mysql -uroot -p <<EOT
   CREATE DATABASE $db_name;
   CREATE USER '$user'@'localhost' IDENTIFIED BY '$password';
   GRANT ALL PRIVILEGES ON *.* to '$user'@'localhost' WITH GRANT OPTION;
EOT
fi

#===================================TeamCity
read -p "Do you want to download and install TeamCity? [y/n]" answer
if [ $answer == "y" ]; then
  wget https://download.jetbrains.com/teamcity/TeamCity-2024.03.1.tar.gz
  tar -xzf TeamCity-2024.03.1.tar.gz
  mkdir /opt/JetBrains
  mv TeamCity /opt/JetBrains/TeamCity
  rm TeamCity-2024.03.1.tar.gz
  cd /opt/JetBrains/TeamCity
  chown -R ubuntu /opt/JetBrains/TeamCity
  cat <<"EOT" >>/etc/systemd/system/teamcity.service
  [Unit]
  Description=TeamCity Build Agent

  [Service]
  Type=oneshot
  User=ubuntu
  ExecStart=/opt/JetBrains/TeamCity/bin/runAll.sh start
  ExecStop=-/opt/JetBrains/TeamCity/bin/runAll.sh stop
  RemainAfterExit=yes

  [Install]
  WantedBy=default.target
EOT
  systemctl daemon-reload
  systemctl enable teamcity
  cat <<"EOT" >>/etc/init.d/teamcity
	#!/bin/bash
	### BEGIN INIT INFO
	# Provides:          TeamCity autostart
	# Required-Start:    $remote_fs $syslog
	# Required-Stop:     $remote_fs $syslog
	# Default-Start:     2 3 4 5
	# Default-Stop:      0 1 6
	# Short-Description: Start teamcity daemon at boot time
	# Description:       Enable service provided by daemon.
	# /etc/init.d/teamcity - startup script for teamcity
	### END INIT INFO

	export TEAMCITY_DATA_PATH='/opt/JetBrains/TeamCity/.BuildServer'
	case $1 in
		start)
			start-stop-daemon --start -c ubuntu:ubuntu --exec /opt/JetBrains/TeamCity/bin/runAll.sh start
			;;
		stop)
			start-stop-daemon --start -c ubuntu:ubuntu --exec /opt/JetBrains/TeamCity/bin/runAll.sh stop
			;;
	esac
	exit 0
EOT
  chmod +x /etc/init.d/teamcity
  update-rc.d teamcity enable 2 3 4 5
  /etc/init.d/teamcity start
fi

#===================================Nginx
read -p "Do you want to install nginx (for proxying teamcity to 80 port)? [y/n]" answer
if [ $answer == "y" ]; then
  apt update
  apt-get install nginx
  read -e -p "Server name [localhost]: " -i "localhost" server_name
  cat <<EOT >>/etc/nginx/sites-available/teamcity
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''   '';
}

server {
    listen       80;
    server_name  $server_name;

    proxy_read_timeout     1200;
    proxy_connect_timeout  240;
    client_max_body_size   256M;

    location / {
        proxy_pass          http://localhost:8111/;
        proxy_http_version  1.1;
        proxy_set_header    X-Forwarded-For \$remote_addr;
        proxy_set_header    Host \$server_name:\$server_port;
        proxy_set_header    Upgrade \$http_upgrade;
        proxy_set_header    Connection \$connection_upgrade;
    }
}
EOT
  ln -s /etc/nginx/sites-available/teamcity /etc/nginx/sites-enabled/teamcity
  rm /etc/nginx/sites-available/default
  rm /etc/nginx/sites-enabled/default
  service nginx restart
fi

#===================================LetsEncrypt
read -p "Do you want to activate SSL with LetsEncrypt? [y/n]" answer
if [ $answer == "y" ]; then
  apt update
  apt install python3-certbot-nginx
  read -e -p "Server name: " server_name
  certbot --nginx -d $server_name
fi
