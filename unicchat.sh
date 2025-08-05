#!/usr/bin/env bash
#
# UnicChat installation helper (обновлено 2025-08-05)
#

set -euo pipefail

# Ensure running as root or via sudo
if [[ $EUID -ne 0 ]]; then
  echo "🚫 This script must be run as root or with sudo."
  exit 1
fi

# Load or initialize DOMAIN and EMAIL from domain.usr.txt
DOMAIN=""
EMAIL=""
CONFIG_FILE="domain.usr.txt"

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    echo "📄 Loading domain and email from $CONFIG_FILE..."
    DOMAIN=$(grep '^DOMAIN=' "$CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    EMAIL=$(grep '^EMAIL=' "$CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
  else
    echo "🔧 First-time setup:"
    while [ -z "$DOMAIN" ]; do
      read -rp "🌍 Enter the domain name (e.g. example.com): " DOMAIN
    done
    while [ -z "$EMAIL" ]; do
      read -rp "📧 Enter contact email for Let's Encrypt: " EMAIL
    done
    echo "DOMAIN=$DOMAIN" > "$CONFIG_FILE"
    echo "EMAIL=$EMAIL" >> "$CONFIG_FILE"
    echo "✅ Configuration saved to $CONFIG_FILE"
  fi
}

install_deps() {
  echo -e "\n🔧 Adding Docker APT repository and installing dependencies…"

  apt update -y
  apt install -y ca-certificates curl gnupg lsb-release software-properties-common

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release; echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt update -y
  apt install -y docker.io docker-compose-plugin docker-compose nginx certbot python3-certbot-nginx git dnsutils

  echo "✅ Dependencies installed (including docker compose plugin)."
}

docker_compose() {
  if command -v docker compose >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "❌ docker compose not found."
    exit 1
  fi
}

clone_repo() {
  echo -e "\n📥 Cloning repository…"
  if [ ! -d unicchat ]; then
    git clone https://github.com/unicommorg/unicchat.git
  else
    echo "📁 Repository already exists."
  fi
  (cd unicchat && git fetch --all && git switch main)
  echo "✅ Repo ready on branch main."
}

check_avx() {
  echo -e "\n🧠 Checking CPU for AVX…"
  if grep -m1 -q avx /proc/cpuinfo; then
    echo "✅ AVX supported. You can use MongoDB 5.x+"
  else
    echo "⚠️ No AVX. Use MongoDB 4.4"
  fi
}

setup_domain() {
  echo -e "\n🌐 Writing domain into configs and checking DNS…"
  echo "$DOMAIN" > "unicchat/nginx/domain.txt"
  echo "$DOMAIN" > "unicchat/domain.txt"
  dig "$DOMAIN" +short || true
  echo "✅ Domain set."
}

generate_nginx_conf() {
  echo -e "\n🛠️ Generating Nginx config…"
  (cd unicchat && chmod +x ./nginx/generate_nginx_conf.sh && ./nginx/generate_nginx_conf.sh)
}

backup_nginx_conf() {
  local target="/etc/nginx/sites-available/$DOMAIN.conf"
  if [ -f "$target" ]; then
    local backup="${target}.bak_$(date +%Y%m%d%H%M%S)"
    echo "💾 Backing up existing config to $backup"
    cp "$target" "$backup"
  fi
}

deploy_nginx_conf() {
  echo -e "\n📤 Deploying Nginx config…"
  local conf=""
  for path in \
    "unicchat/$DOMAIN.conf" \
    "unicchat/$DOMAIN" \
    "unicchat/nginx/$DOMAIN.conf" \
    "unicchat/nginx/$DOMAIN"
  do
    [ -f "$path" ] && conf="$path" && break
  done

  if [ -z "$conf" ]; then
    echo "❌ Config not found. Run step 5 first."
    return
  fi

  backup_nginx_conf
  cp "$conf" "/etc/nginx/sites-available/$DOMAIN.conf"
  [ -f "unicchat/nginx/options-ssl-nginx.conf" ] && cp "unicchat/nginx/options-ssl-nginx.conf" "/etc/letsencrypt/"
  echo "✅ Config deployed."
}

setup_ssl() {
  echo -e "\n🔐 Requesting SSL certificate…"
  certbot --nginx --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
  echo -e "\n⏳ Generating DH parameters…"
  mkdir -p /etc/letsencrypt
  openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
  echo "✅ SSL and DH ready."
}

activate_nginx() {
  echo -e "\n🚀 Activating Nginx site…"
  ln -sf "/etc/nginx/sites-available/$DOMAIN.conf" "/etc/nginx/sites-enabled/$DOMAIN.conf"
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t && systemctl reload nginx
  echo "✅ Nginx activated."
}

prepare_unicchat() {
  echo -e "\n📦 Preparing env files…"
  local dir="unicchat/single-server-install"
  (cd "$dir" && chmod +x generate_env_files.sh && ./generate_env_files.sh)
  echo "✅ Env ready."
}

login_yandex() {
  echo -e "\n🔑 Logging into Yandex Container Registry…"
  docker login --username oauth \
    --password y0_AgAAAAB3muX6AATuwQAAAAEawLLRAAB9TQHeGyxGPZXkjVDHF1ZNJcV8UQ \
    cr.yandex
  echo "✅ Logged in."
}

start_unicchat() {
  echo -e "\n🚀 Starting UnicChat services…"
  local dir="unicchat/single-server-install"
  docker network inspect unicchat-backend >/dev/null 2>&1 || docker network create unicchat-backend
  docker network inspect unicchat-frontend >/dev/null 2>&1 || docker network create unicchat-frontend
  (cd "$dir" && docker_compose -f unicchat.yml up -d)
  echo "✅ Services started."
}

update_site_url() {
  echo -e "\n📝 Updating Site_Url in MongoDB…"
  local dir="unicchat/single-server-install"
  local env_file="$dir/mongo.env"
  local container="unic.chat.db.mongo"
  local pwd=$(grep -E '^MONGODB_ROOT_PASSWORD=' "$env_file" | cut -d '=' -f2 | tr -d '\r')
  local url="https://$DOMAIN"
  docker exec "$container" mongosh -u root -p "$pwd" --quiet --eval "db.getSiblingDB('unicchat_db').rocketchat_settings.updateOne({_id:'Site_Url'},{\$set:{value:'$url'}})"
  docker exec "$container" mongosh -u root -p "$pwd" --quiet --eval "db.getSiblingDB('unicchat_db').rocketchat_settings.updateOne({_id:'Site_Url'},{\$set:{packageValue:'$url'}})"
  echo "✅ Site_Url updated."
}

auto_setup() {
  echo -e "\n⚙️ Running full automatic setup…"
  install_deps
  clone_repo
  check_avx
  setup_domain
  generate_nginx_conf
  deploy_nginx_conf
  setup_ssl
  activate_nginx
  prepare_unicchat
  login_yandex
  start_unicchat
  update_site_url
  echo -e "\n🎉 UnicChat setup complete!"
}

main_menu() {
  echo -e "\n✨ Welcome to UnicChat Installer"
  echo -e "✅ Domain: $DOMAIN | Email: $EMAIL\n"
  while true; do
    cat <<MENU
 [1]  Install dependencies
 [2]  Clone repository
 [3]  Check AVX support
 [4]  Setup domain and check DNS
 [5]  Generate Nginx config
 [6]  Deploy Nginx config (with backup)
 [7]  Setup SSL certificate
 [8]  Activate Nginx site
 [9]  Prepare .env files
[10]  Login to Yandex registry
[11]  Start UnicChat containers
[12]  Update MongoDB Site_Url
[99]  🚀 Full automatic setup
 [0]  Exit
MENU
    read -rp "👉 Select an option: " choice
    case $choice in
      1) install_deps ;;
      2) clone_repo ;;
      3) check_avx ;;
      4) setup_domain ;;
      5) generate_nginx_conf ;;
      6) deploy_nginx_conf ;;
      7) setup_ssl ;;
      8) activate_nginx ;;
      9) prepare_unicchat ;;
      10) login_yandex ;;
      11) start_unicchat ;;
      12) update_site_url ;;
      99) auto_setup ;;
      0) echo "👋 Goodbye!" && break ;;
      *) echo "❓ Invalid option." ;;
    esac
    echo ""
  done
}

# === Start ===
load_config
main_menu "$@"
