#!/bin/bash

set -e

#############################################################################
#                                                                           #
# Project 'pterodactyl-installer' for panel                                 #
#                                                                           #
# Copyright (C) 2018 - 2021, Vilhelm Prytz, <vilhelm@prytznet.se>           #
#                                                                           #
#   This program is free software: you can redistribute it and/or modify    #
#   it under the terms of the GNU General Public License as published by    #
#   the Free Software Foundation, either version 3 of the License, or       #
#   (at your option) any later version.                                     #
#                                                                           #
#   This program is distributed in the hope that it will be useful,         #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#   GNU General Public License for more details.                            #
#                                                                           #
#   You should have received a copy of the GNU General Public License       #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.  #
#                                                                           #
# https://github.com/vilhelmprytz/pterodactyl-installer/blob/master/LICENSE #
#                                                                           #
# This script is not associated with the official Pterodactyl Project.      #
# https://github.com/vilhelmprytz/pterodactyl-installer                     #
#                                                                           #
#############################################################################

######## General checks #########

# exit with error status code if user is not root
if [[ $EUID -ne 0 ]]; then
  echo "* This script must be executed with root privileges (sudo)." 1>&2
  exit 1
fi

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
  exit 1
fi

########## Variables ############

# versioning
GITHUB_SOURCE="master"
SCRIPT_RELEASE="canary"

FQDN=""

# Default MySQL credentials
MYSQL_DB="pterodactyl"
MYSQL_USER="pterodactyl"
MYSQL_PASSWORD=""

# Environment
email=""

# Initial admin account
user_email="franciscor00@outlook.es"
user_username="admin"
user_firstname="admin"
user_lastname="admin"
user_password="Treckk001*"

# Assume SSL, will fetch different config if true
ASSUME_SSL=false
CONFIGURE_LETSENCRYPT=false

# download URLs
PANEL_DL_URL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
GITHUB_BASE_URL="https://raw.githubusercontent.com/vilhelmprytz/pterodactyl-installer/$GITHUB_SOURCE"

# ufw firewall
CONFIGURE_UFW=false

# firewall_cmd
CONFIGURE_FIREWALL_CMD=false

# firewall status
CONFIGURE_FIREWALL=false

# regex for email input
regex="^(([A-Za-z0-9]+((\.|\-|\_|\+)?[A-Za-z0-9]?)*[A-Za-z0-9]+)|[A-Za-z0-9]+)@(([A-Za-z0-9]+)+((\.|\-|\_)?([A-Za-z0-9]+)+)*)+\.([A-Za-z]{2,})+$"

PHPMYADMIN=5.1.1

####### Version checking ########

# define version using information from GitHub
get_latest_release() {
  curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
    grep '"tag_name":' |                                            # Get tag line
    sed -E 's/.*"([^"]+)".*/\1/'                                    # Pluck JSON value
}

# pterodactyl version
echo "* Retrieving release information.."
PTERODACTYL_VERSION="$(get_latest_release "pterodactyl/panel")"

####### lib func #######

array_contains_element() {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

valid_email() {
  [[ $1 =~ ${regex} ]]
}

####### Visual functions ########

print_error() {
  COLOR_RED='\033[0;31m'
  COLOR_NC='\033[0m'

  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1"
  echo ""
}

print_warning() {
  COLOR_YELLOW='\033[1;33m'
  COLOR_NC='\033[0m'
  echo ""
  echo -e "* ${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
  echo ""
}

print_brake() {
  for ((n = 0; n < $1; n++)); do
    echo -n "#"
  done
  echo ""
}

hyperlink() {
  echo -e "\e]8;;${1}\a${1}\e]8;;\a"
}

##### User input functions ######

required_input() {
  local __resultvar=$1
  local result=''

  while [ -z "$result" ]; do
    echo -n "* ${2}"
    read -r result

    [ -z "$result" ] && print_error "${3}"
  done

  eval "$__resultvar="'$result'""
}

email_input() {
  local __resultvar=$1
  local result=''

  while ! valid_email "$result"; do
    echo -n "* ${2}"
    read -r result

    valid_email "$result" || print_error "${3}"
  done

  eval "$__resultvar="'$result'""
}

password_input() {
  local __resultvar=$1
  local result=''
  local default="$4"

  while [ -z "$result" ]; do
    echo -n "* ${2}"

    # modified from https://stackoverflow.com/a/22940001
    while IFS= read -r -s -n1 char; do
      [[ -z $char ]] && {
        printf '\n'
        break
      }                               # ENTER pressed; output \n and break.
      if [[ $char == $'\x7f' ]]; then # backspace was pressed
        # Only if variable is not empty
        if [ -n "$result" ]; then
          # Remove last char from output variable.
          [[ -n $result ]] && result=${result%?}
          # Erase '*' to the left.
          printf '\b \b'
        fi
      else
        # Add typed char to output variable.
        result+=$char
        # Print '*' in its stead.
        printf '*'
      fi
    done
    [ -z "$result" ] && [ -n "$default" ] && result="$default"
    [ -z "$result" ] && print_error "${3}"
  done

  eval "$__resultvar="'$result'""
}

ask_letsencrypt() {
  if [ "$CONFIGURE_UFW" == false ] && [ "$CONFIGURE_FIREWALL_CMD" == false ]; then
    print_warning "Let's Encrypt requires port 80/443 to be opened! You have opted out of the automatic firewall configuration; use this at your own risk (if port 80/443 is closed, the script will fail)!"
  fi

  print_warning "You cannot use Let's Encrypt with your hostname as an IP address! It must be a FQDN (e.g. panel.example.org)."

  echo -e -n "* Do you want to automatically configure HTTPS using Let's Encrypt? (y/N): "
  read -r CONFIRM_SSL

  if [[ "$CONFIRM_SSL" =~ [Yy] ]]; then
    CONFIGURE_LETSENCRYPT=true
    ASSUME_SSL=false
  fi
}

ask_assume_ssl() {
  echo "* Let's Encrypt is not going to be automatically configured by this script (user opted out)."
  echo "* You can 'assume' Let's Encrypt, which means the script will download a nginx configuration that is configured to use a Let's Encrypt certificate but the script won't obtain the certificate for you."
  echo "* If you assume SSL and do not obtain the certificate, your installation will not work."
  echo -n "* Assume SSL or not? (y/N): "
  read -r ASSUME_SSL_INPUT

  [[ "$ASSUME_SSL_INPUT" =~ [Yy] ]] && ASSUME_SSL=true
  true
}

ask_firewall() {
  case "$OS" in
  ubuntu | debian)
    echo -e -n "* Do you want to automatically configure UFW (firewall)? (y/N): "
    read -r CONFIRM_UFW

    if [[ "$CONFIRM_UFW" =~ [Yy] ]]; then
      CONFIGURE_UFW=true
      CONFIGURE_FIREWALL=true
    fi
    ;;
  centos)
    echo -e -n "* Do you want to automatically configure firewall-cmd (firewall)? (y/N): "
    read -r CONFIRM_FIREWALL_CMD

    if [[ "$CONFIRM_FIREWALL_CMD" =~ [Yy] ]]; then
      CONFIGURE_FIREWALL_CMD=true
      CONFIGURE_FIREWALL=true
    fi
    ;;
  esac
}

####### OS check funtions #######

detect_distro() {
  if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$(echo "$ID" | awk '{print tolower($0)}')
    OS_VER=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si | awk '{print tolower($0)}')
    OS_VER=$(lsb_release -sr)
  elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$(echo "$DISTRIB_ID" | awk '{print tolower($0)}')
    OS_VER=$DISTRIB_RELEASE
  elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS="debian"
    OS_VER=$(cat /etc/debian_version)
  elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    OS="SuSE"
    OS_VER="?"
  elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    OS="Red Hat/CentOS"
    OS_VER="?"
  else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    OS_VER=$(uname -r)
  fi

  OS=$(echo "$OS" | awk '{print tolower($0)}')
  OS_VER_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
}

check_os_comp() {
  CPU_ARCHITECTURE=$(uname -m)
  if [ "${CPU_ARCHITECTURE}" != "x86_64" ]; then # check the architecture
    print_warning "Detected CPU architecture $CPU_ARCHITECTURE"
    print_warning "Using any other architecture than 64 bit (x86_64) will cause problems."

    echo -e -n "* Are you sure you want to proceed? (y/N):"
    read -r choice

    if [[ ! "$choice" =~ [Yy] ]]; then
      print_error "Installation aborted!"
      exit 1
    fi
  fi

  case "$OS" in
  ubuntu)
    PHP_SOCKET="/run/php/php8.0-fpm.sock"
    [ "$OS_VER_MAJOR" == "18" ] && SUPPORTED=true
    [ "$OS_VER_MAJOR" == "20" ] && SUPPORTED=true
    ;;
  debian)
    PHP_SOCKET="/run/php/php8.0-fpm.sock"
    [ "$OS_VER_MAJOR" == "9" ] && SUPPORTED=true
    [ "$OS_VER_MAJOR" == "10" ] && SUPPORTED=true
    ;;
  centos)
    PHP_SOCKET="/var/run/php-fpm/pterodactyl.sock"
    [ "$OS_VER_MAJOR" == "7" ] && SUPPORTED=true
    [ "$OS_VER_MAJOR" == "8" ] && SUPPORTED=true
    ;;
  *)
    SUPPORTED=false
    ;;
  esac

  # exit if not supported
  if [ "$SUPPORTED" == true ]; then
    echo "* $OS $OS_VER is supported."
  else
    echo "* $OS $OS_VER is not supported"
    print_error "Unsupported OS"
    exit 1
  fi
}

##### Main installation functions #####

# Install composer
install_composer() {
  echo "* Installing composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  echo "* Composer installed!"
}

# Download pterodactyl files
ptdl_dl() {
  echo "* Downloading pterodactyl panel files .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit

  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env
  [ "$OS" == "centos" ] && export PATH=/usr/local/bin:$PATH
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

  php artisan key:generate --force
  echo "* Downloaded pterodactyl panel files & installed composer dependencies!"
}

# Create a databse with user
create_database() {
  if [ "$OS" == "centos" ]; then
    # secure MariaDB
    echo "* MySQL secure installation. The following are safe defaults."
    echo "* Set root password? [Y/n] Y"
    echo "* Remove anonymous users? [Y/n] Y"
    echo "* Disallow root login remotely? [Y/n] Y"
    echo "* Remove test database and access to it? [Y/n] Y"
    echo "* Reload privilege tables now? [Y/n] Y"
    echo "*"

    mysql_secure_installation

    echo "* The script should have asked you to set the MySQL root password earlier (not to be confused with the pterodactyl database user password)"
    echo "* MySQL will now ask you to enter the password before each command."

    echo "* Create MySQL user."
    mysql -u root -p -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"

    echo "* Create database."
    mysql -u root -p -e "CREATE DATABASE ${MYSQL_DB};"

    echo "* Grant privileges."
    mysql -u root -p -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;"

    echo "* Flush privileges."
    mysql -u root -p -e "FLUSH PRIVILEGES;"
  else
    echo "* Performing MySQL queries.."

    echo "* Creating MySQL user.."
    mysql -u root -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"

    echo "* Creating database.."
    mysql -u root -e "CREATE DATABASE ${MYSQL_DB};"

    echo "* Granting privileges.."
    mysql -u root -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;"

    echo "* Flushing privileges.."
    mysql -u root -e "FLUSH PRIVILEGES;"

    echo "* MySQL database created & configured!"
  fi
}

# Configure environment
configure() {
  app_url="http://$FQDN"
  [ "$ASSUME_SSL" == true ] && app_url="https://$FQDN"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && app_url="https://$FQDN"

  # Fill in environment:setup automatically
  php artisan p:environment:setup \
    --author="$email" \
    --url="$app_url" \
    --timezone="$timezone" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui=true

  # Fill in environment:database credentials automatically
  php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQL_USER" \
    --password="$MYSQL_PASSWORD"

  # configures database
  php artisan migrate --seed --force

  # Create user account
  php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1
}

# set the correct folder permissions depending on OS and webserver
set_folder_permissions() {
  # if os is ubuntu or debian, we do this
  case "$OS" in
  debian | ubuntu)
    chown -R www-data:www-data ./*
    ;;
  centos)
    chown -R nginx:nginx ./*
    ;;
  esac
}

# insert cronjob
insert_cronjob() {
  echo "* Installing cronjob.. "

  crontab -l | {
    cat
    echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"
  } | crontab -

  echo "* Cronjob installed!"
}

install_pteroq() {
  echo "* Installing pteroq service.."

  curl -o /etc/systemd/system/pteroq.service $GITHUB_BASE_URL/configs/pteroq.service

  case "$OS" in
  debian | ubuntu)
    sed -i -e "s@<user>@www-data@g" /etc/systemd/system/pteroq.service
    ;;
  centos)
    sed -i -e "s@<user>@nginx@g" /etc/systemd/system/pteroq.service
    ;;
  esac

  systemctl enable pteroq.service
  systemctl start pteroq

  echo "* Installed pteroq!"
}

##### OS specific install functions #####

apt_update() {
  apt update -q -y && apt upgrade -y
}

yum_update() {
  yum -y update
}

dnf_update() {
  dnf -y upgrade
}

enable_services_debian_based() {
  systemctl enable mysql
  systemctl enable redis-server
  systemctl start mysql
  systemctl start redis-server
}

enable_services_centos_based() {
  systemctl enable mysql
  systemctl enable nginx
  systemctl enable redis
  systemctl start mysql
  systemctl start redis
}

selinux_allow() {
  setsebool -P httpd_can_network_connect 1 || true # these commands can fail OK
  setsebool -P httpd_execmem 1 || true
  setsebool -P httpd_unified 1 || true
}

ubuntu20_dep() {
  echo "* Installing dependencies for Ubuntu 20.."

  # Add "add-apt-repository" command
  apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

  # Ubuntu universe repo
  add-apt-repository universe

  # Add PPA for PHP (we need 8.0 and focal only has 7.4)
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

  # Update repositories list
  apt_update

  # Install Dependencies
  apt -y install php8.0 php8.0-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} nginx tar unzip git redis-server redis cron

  sudo apt install wget -y
  wget https://dev.mysql.com/get/mysql-apt-config_0.8.12-1_all.deb

  sudo dpkg -i mysql-apt-config_0.8.12-1_all.deb

  apt_update

  sudo apt install -f mysql-client=5.7* mysql-community-server=5.7* mysql-server=5.7*

  # Enable services
  enable_services_debian_based

  echo "* Dependencies for Ubuntu installed!"
}


##### OTHER OS SPECIFIC FUNCTIONS #####

centos_php() {
  curl -o /etc/php-fpm.d/www-pterodactyl.conf $GITHUB_BASE_URL/configs/www-pterodactyl.conf

  systemctl enable php-fpm
  systemctl start php-fpm
}

firewall_ufw() {
  apt install -y ufw

  echo -e "\n* Enabling Uncomplicated Firewall (UFW)"
  echo "* Opening port 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

  # pointing to /dev/null silences the command output
  ufw allow ssh >/dev/null
  ufw allow http >/dev/null
  ufw allow https >/dev/null

  ufw --force enable
  ufw --force reload
  ufw status numbered | sed '/v6/d'
}

firewall_firewalld() {
  echo -e "\n* Enabling firewall_cmd (firewalld)"
  echo "* Opening port 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

  # Install
  [ "$OS_VER_MAJOR" == "7" ] && yum -y -q install firewalld >/dev/null
  [ "$OS_VER_MAJOR" == "8" ] && dnf -y -q install firewalld >/dev/null

  # Enable
  systemctl --now enable firewalld >/dev/null # Enable and start

  # Configure
  firewall-cmd --add-service=http --permanent -q  # Port 80
  firewall-cmd --add-service=https --permanent -q # Port 443
  firewall-cmd --add-service=ssh --permanent -q   # Port 22
  firewall-cmd --reload -q                        # Enable firewall

  echo "* Firewall-cmd installed"
  print_brake 70
}

letsencrypt() {
  FAILED=false

  # Install certbot
  case "$OS" in
  debian | ubuntu)
    apt-get -y install certbot python3-certbot-nginx
    ;;
  centos)
    [ "$OS_VER_MAJOR" == "7" ] && yum -y -q install certbot python-certbot-nginx
    [ "$OS_VER_MAJOR" == "8" ] && dnf -y -q install certbot python3-certbot-nginx
    ;;
  esac

  # Obtain certificate
  certbot --nginx --redirect --no-eff-email --email "$email" -d "$FQDN" || FAILED=true

  # Check if it succeded
  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
    print_warning "The process of obtaining a Let's Encrypt certificate failed!"
    echo -n "* Still assume SSL? (y/N): "
    read -r CONFIGURE_SSL

    if [[ "$CONFIGURE_SSL" =~ [Yy] ]]; then
      ASSUME_SSL=true
      CONFIGURE_LETSENCRYPT=false
      configure_nginx
    else
      ASSUME_SSL=false
      CONFIGURE_LETSENCRYPT=false
    fi
  fi
}

##### WEBSERVER CONFIGURATION FUNCTIONS #####

configure_nginx() {
  echo "* Configuring nginx .."

  if [ $ASSUME_SSL == true ] && [ $CONFIGURE_LETSENCRYPT == false ]; then
    DL_FILE="nginx_ssl.conf"
  else
    DL_FILE="nginx.conf"
  fi

  if [ "$OS" == "centos" ]; then
    # remove default config
    rm -rf /etc/nginx/conf.d/default

    # download new config
    curl -o /etc/nginx/conf.d/pterodactyl.conf $GITHUB_BASE_URL/configs/$DL_FILE

    # replace all <domain> places with the correct domain
    sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/conf.d/pterodactyl.conf

    # replace all <php_socket> places with correct socket "path"
    sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" /etc/nginx/conf.d/pterodactyl.conf
  else
    # remove default config
    rm -rf /etc/nginx/sites-enabled/default

    # download new config
    curl -o /etc/nginx/sites-available/pterodactyl.conf $GITHUB_BASE_URL/configs/$DL_FILE

    # replace all <domain> places with the correct domain
    sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/sites-available/pterodactyl.conf

    # replace all <php_socket> places with correct socket "path"
    sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" /etc/nginx/sites-available/pterodactyl.conf

    # on debian 9, TLS v1.3 is not supported (see #76)
    [ "$OS" == "debian" ] && [ "$OS_VER_MAJOR" == "9" ] && sed -i 's/ TLSv1.3//' /etc/nginx/sites-available/pterodactyl.conf

    # enable pterodactyl
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  fi

  if [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    systemctl restart nginx
  fi

  echo "* nginx configured!"
}

install_theme() {
  echo "*installation Theme.. this might take a while!"

  cd /var/www/pterodactyl
  mkdir -p tempdown && cd tempdown && git clone https://github.com/treckk00/pageDesign.git .

  cp -r app ..
  cp -r config ..
  cp -r database ..
  cp -r public ..
  cp -r resources ..
  cp -r routes ..

  cd .. && rm -rf tempdown
  php artisan migrate --path=/database/migrations/2021_05_30_141248_create_unix_settings_table.php
}

install_phpmyadmin(){
    echo "Installing phpMyAdmin..."

    cd /var/www/pterodactyl/public
    rm -rf phpmyadmin
    wget https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN}/phpMyAdmin-${PHPMYADMIN}-all-languages.zip
    unzip phpMyAdmin-${PHPMYADMIN}-all-languages.zip
    mv phpMyAdmin-${PHPMYADMIN}-all-languages phpmyadmin
    rm -rf phpMyAdmin-${PHPMYADMIN}-all-languages.zip
    cd /var/www/pterodactyl/public/phpmyadmin

    SERVER_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
    BOWFISH=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 34 | head -n 1`
    bash -c 'cat > /var/www/pterodactyl/public/phpmyadmin/config.inc.php' <<EOF
<?php
/* Servers configuration */
\$i = 0;
/* Server: MySQL [1] */
\$i++;
\$cfg['Servers'][\$i]['verbose'] = 'MySQL';
\$cfg['Servers'][\$i]['host'] = '${SERVER_IP}';
\$cfg['Servers'][\$i]['port'] = '';
\$cfg['Servers'][\$i]['socket'] = '';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['user'] = 'root';
\$cfg['Servers'][\$i]['password'] = '';
/* End of servers configuration */
\$cfg['blowfish_secret'] = '${BOWFISH}';
\$cfg['DefaultLang'] = 'en';
\$cfg['ServerDefault'] = 1;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['CaptchaLoginPublicKey'] = '6LcJcjwUAAAAAO_Xqjrtj9wWufUpYRnK6BW8lnfn';
\$cfg['CaptchaLoginPrivateKey'] = '6LcJcjwUAAAAALOcDJqAEYKTDhwELCkzUkNDQ0J5'
?>    
EOF
    echo "Installation completed."
    if [ "$lsb_dist" =  "ubuntu" ] || [ "$lsb_dist" =  "debian" ]; then
        chown -R www-data:www-data * /var/www/pterodactyl
    elif [ "$lsb_dist" =  "fedora" ] || [ "$lsb_dist" =  "centos" ] || [ "$lsb_dist" =  "rhel" ]; then
        chown -R apache:apache * /var/www/pterodactyl
        chown -R nginx:nginx * /var/www/pterodactyl
        semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/pterodactyl/storage(/.*)?"
        restorecon -R /var/www/pterodactyl
    fi
}


##### MAIN FUNCTIONS #####

perform_install() {
  echo "* Starting installation.. this might take a while!"

  case "$OS" in
  debian | ubuntu)
    apt_update

    if [ "$OS" == "ubuntu" ]; then
      [ "$OS_VER_MAJOR" == "20" ] && ubuntu20_dep
    fi
    ;;
  esac

  [ "$OS" == "centos" ] && centos_php
  install_composer
  ptdl_dl
  create_database
  configure
  set_folder_permissions
  insert_cronjob
  install_pteroq
  configure_nginx
  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt
  install_theme
  install_phpmyadmin
  true
}

main() {
  # check if we can detect an already existing installation
  if [ -d "/var/www/pterodactyl" ]; then
    print_warning "The script has detected that you already have Pterodactyl panel on your system! You cannot run the script multiple times, it will fail!"
    echo -e -n "* Are you sure you want to proceed? (y/N): "
    read -r CONFIRM_PROCEED
    if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
      print_error "Installation aborted!"
      exit 1
    fi
  fi

  # detect distro
  detect_distro

  print_brake 70
  echo "* Pterodactyl panel installation script @ $SCRIPT_RELEASE"
  echo "*"
  echo "* Copyright (C) 2018 - 2021, Vilhelm Prytz, <vilhelm@prytznet.se>"
  echo "* https://github.com/vilhelmprytz/pterodactyl-installer"
  echo "*"
  echo "* This script is not associated with the official Pterodactyl Project."
  echo "*"
  echo "* Running $OS version $OS_VER."
  echo "* Latest pterodactyl/panel is $PTERODACTYL_VERSION"
  print_brake 70

  # checks if the system is compatible with this installation script
  check_os_comp

  # set database credentials
  print_brake 72
  echo "* Database configuration."
  echo ""
  echo "* This will be the credentials used for communication between the MySQL"
  echo "* database and the panel. You do not need to create the database"
  echo "* before running this script, the script will do that for you."
  echo ""

  readarray -t valid_timezones <<<"$(curl -s $GITHUB_BASE_URL/configs/valid_timezones.txt)"
  echo "* List of valid timezones here $(hyperlink "https://www.php.net/manual/en/timezones.php")"

  while [ -z "$timezone" ]; do
    echo -n "* Select timezone [Europe/Stockholm]: "
    read -r timezone_input

    array_contains_element "$timezone_input" "${valid_timezones[@]}" && timezone="$timezone_input"
    [ -z "$timezone_input" ] && timezone="Europe/Stockholm" # because köttbullar!
  done

  email_input email "Provide the email address that will be used to configure Let's Encrypt and Pterodactyl: " "Email cannot be empty or invalid"

  print_brake 72

  # set FQDN
  while [ -z "$FQDN" ]; do
    echo -n "* Set the FQDN of this panel (panel.example.com): "
    read -r FQDN
    [ -z "$FQDN" ] && print_error "FQDN cannot be empty"
  done

  # Ask if firewall is needed

  # Ask if letsencrypt is needed
  ask_letsencrypt

  # If it's already true, this should be a no-brainer
  [ "$CONFIGURE_LETSENCRYPT" == false ] && ask_assume_ssl

  # verify FQDN if user has selected to assume SSL or configure Let's Encrypt
  [ "$CONFIGURE_LETSENCRYPT" == true ] || [ "$ASSUME_SSL" == true ] && bash <(curl -s $GITHUB_BASE_URL/lib/verify-fqdn.sh) "$FQDN" "$OS"

  # summary
  summary

  # confirm installation
  echo -e -n "\n* Initial configuration completed. Continue with installation? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Yy] ]]; then
    perform_install
  else
    # run welcome script again
    print_error "Installation aborted."
    exit 1
  fi
}

summary() {
  print_brake 62
  echo "* Pterodactyl panel $PTERODACTYL_VERSION with nginx on $OS"
  echo "* Database name: $MYSQL_DB"
  echo "* Database user: $MYSQL_USER"
  echo "* Database password: (censored)"
  echo "* Timezone: $timezone"
  echo "* Email: $email"
  echo "* User email: $user_email"
  echo "* Username: $user_username"
  echo "* First name: $user_firstname"
  echo "* Last name: $user_lastname"
  echo "* User password: (censored)"
  echo "* Hostname/FQDN: $FQDN"
  echo "* Configure Firewall? $CONFIGURE_FIREWALL"
  echo "* Configure Let's Encrypt? $CONFIGURE_LETSENCRYPT"
  echo "* Assume SSL? $ASSUME_SSL"
  print_brake 62
}

goodbye() {
  print_brake 62
  echo "* Panel installation completed"
  echo "*"

  [ "$CONFIGURE_LETSENCRYPT" == true ] && echo "* Your panel should be accessible from $(hyperlink "$app_url")"
  [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && echo "* You have opted in to use SSL, but not via Let's Encrypt automatically. Your panel will not work until SSL has been configured."
  [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && echo "* Your panel should be accessible from $(hyperlink "$app_url")"

  echo "*"
  echo "* Installation is using nginx on $OS"
  echo "* Thank you for using this script."
  [ "$CONFIGURE_FIREWALL" == false ] && echo -e "* ${COLOR_RED}Note${COLOR_NC}: If you haven't configured the firewall: 80/443 (HTTP/HTTPS) is required to be open!"
  print_brake 62
}

# run script
main
goodbye
