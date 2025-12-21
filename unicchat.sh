#!/usr/bin/env bash
#
# UnicChat installation helper (обновлено 2025-01-XX)
#

set -euo pipefail

# Ensure running as root or via sudo
if [[ $EUID -ne 0 ]]; then
  echo "🚫 This script must be run as root or with sudo."
  exit 1
fi

# Load or initialize DOMAIN from unicchat_config.txt
DOMAIN=""
CONFIG_FILE="unicchat_config.txt"
CREDS_CONFIG_FILE="unicchat_creds.txt"

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    echo "📄 Loading domain from $CONFIG_FILE..."
    DOMAIN=$(grep '^DOMAIN=' "$CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    if [ -z "$DOMAIN" ]; then
      echo "⚠️ DOMAIN not found in $CONFIG_FILE, using default: localhost"
      DOMAIN="localhost"
    fi
  else
    echo "🔧 First-time setup:"
    read -rp "🌍 Enter the domain name (e.g. example.com) [default: localhost]: " DOMAIN
    DOMAIN=${DOMAIN:-localhost}
    echo "DOMAIN=$DOMAIN" > "$CONFIG_FILE"
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
  apt install -y docker.io docker-compose-plugin docker-compose git dnsutils

  echo "✅ Dependencies installed."
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

check_avx() {
  echo -e "\n🧠 Checking CPU for AVX…"
  if grep -m1 -q avx /proc/cpuinfo; then
    echo "✅ AVX supported. You can use MongoDB 5.x+"
  else
    echo "⚠️ No AVX. Use MongoDB 4.4"
  fi
}

setup_domain() {
  echo -e "\n🌐 Setting domain and checking DNS…"
  if [ "$DOMAIN" != "localhost" ]; then
    dig "$DOMAIN" +short || true
  fi
  echo "✅ Domain set: $DOMAIN"
  
  # Экспортируем DOMAIN для docker-compose
  export DOMAIN
}


# Функция для запроса значения с дефолтом
ask_value() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local value
  
  if [ -n "$default" ]; then
    read -rp "$prompt [default: $default]: " value
    value=${value:-$default}
  else
    read -rp "$prompt: " value
  fi
  
  eval "$var_name='$value'"
}

# Функция для URL-кодирования (простая версия)
urlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * ) printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done
  echo "${encoded}"
}

prepare_unicchat() {
  echo -e "\n📦 Preparing env files and credentials…"
  local dir="single-server-install"
  
  # Загружаем сохраненные значения, если они есть
  local MONGODB_ROOT_PASSWORD=""
  local MONGODB_USERNAME=""
  local MONGODB_PASSWORD=""
  local MONGODB_DATABASE=""
  local LOGGER_USER=""
  local LOGGER_PASSWORD=""
  local LOGGER_DB=""
  local VAULT_USER=""
  local VAULT_PASSWORD=""
  local VAULT_DB=""
  
  if [ -f "$CREDS_CONFIG_FILE" ]; then
    echo "📄 Loading saved credentials from $CREDS_CONFIG_FILE..."
    MONGODB_ROOT_PASSWORD=$(grep '^MONGODB_ROOT_PASSWORD=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    MONGODB_USERNAME=$(grep '^MONGODB_USERNAME=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    MONGODB_PASSWORD=$(grep '^MONGODB_PASSWORD=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    MONGODB_DATABASE=$(grep '^MONGODB_DATABASE=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    LOGGER_USER=$(grep '^LOGGER_USER=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    LOGGER_PASSWORD=$(grep '^LOGGER_PASSWORD=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    LOGGER_DB=$(grep '^LOGGER_DB=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    VAULT_USER=$(grep '^VAULT_USER=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    VAULT_PASSWORD=$(grep '^VAULT_PASSWORD=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
    VAULT_DB=$(grep '^VAULT_DB=' "$CREDS_CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r')
  fi
  
  echo -e "\n🔐 MongoDB Credentials:"
  ask_value "  MongoDB root password" "${MONGODB_ROOT_PASSWORD:-rootpass}" "MONGODB_ROOT_PASSWORD"
  ask_value "  MongoDB admin username" "${MONGODB_USERNAME:-unicchat_admin}" "MONGODB_USERNAME"
  ask_value "  MongoDB admin password" "${MONGODB_PASSWORD:-secure_password_123}" "MONGODB_PASSWORD"
  ask_value "  MongoDB database name" "${MONGODB_DATABASE:-unicchat_db}" "MONGODB_DATABASE"
  
  echo -e "\n🔐 Logger Service Credentials:"
  ask_value "  Logger MongoDB username" "${LOGGER_USER:-logger_user}" "LOGGER_USER"
  ask_value "  Logger MongoDB password" "${LOGGER_PASSWORD:-logger_pass_123}" "LOGGER_PASSWORD"
  
  echo -e "\n🔐 Vault Service Credentials:"
  ask_value "  Vault MongoDB username" "${VAULT_USER:-vault_user}" "VAULT_USER"
  ask_value "  Vault MongoDB password" "${VAULT_PASSWORD:-vault_pass_123}" "VAULT_PASSWORD"
  
  # Сохраняем значения в файл для повторной установки
  {
    echo "# UnicChat Credentials Configuration"
    echo "# This file is auto-generated. You can edit it for future installations."
    echo ""
    echo "MONGODB_ROOT_PASSWORD=$MONGODB_ROOT_PASSWORD"
    echo "MONGODB_USERNAME=$MONGODB_USERNAME"
    echo "MONGODB_PASSWORD=$MONGODB_PASSWORD"
    echo "MONGODB_DATABASE=$MONGODB_DATABASE"
    echo "LOGGER_USER=$LOGGER_USER"
    echo "LOGGER_PASSWORD=$LOGGER_PASSWORD"
    echo "VAULT_USER=$VAULT_USER"
    echo "VAULT_PASSWORD=$VAULT_PASSWORD"
  } > "$CREDS_CONFIG_FILE"
  
  # URL-кодируем пароли для connection strings
  # Проверяем, не закодирован ли уже пароль (содержит %)
  local LOGGER_PASSWORD_ENCODED
  if [[ "$LOGGER_PASSWORD" == *%* ]]; then
    # Пароль уже закодирован, используем как есть
    LOGGER_PASSWORD_ENCODED="$LOGGER_PASSWORD"
  else
    # Кодируем пароль
    LOGGER_PASSWORD_ENCODED=$(urlencode "$LOGGER_PASSWORD")
  fi
  
  local VAULT_PASSWORD_ENCODED
  if [[ "$VAULT_PASSWORD" == *%* ]]; then
    # Пароль уже закодирован, используем как есть
    VAULT_PASSWORD_ENCODED="$VAULT_PASSWORD"
  else
    # Кодируем пароль
    VAULT_PASSWORD_ENCODED=$(urlencode "$VAULT_PASSWORD")
  fi
  
  # Определяем ROOT_URL
  local ROOT_URL="https://$DOMAIN"
  if [ "$DOMAIN" = "localhost" ]; then
    ROOT_URL="http://localhost:8080"
  fi
  
  # Генерируем mongo.env
  {
    echo "# Replica Set Configuration"
    echo "MONGODB_REPLICA_SET_MODE=primary"
    echo "MONGODB_REPLICA_SET_NAME=rs0"
    echo "MONGODB_REPLICA_SET_KEY=rs0key"
    echo "MONGODB_PORT_NUMBER=27017"
    echo "MONGODB_INITIAL_PRIMARY_HOST=unicchat.mongodb"
    echo "MONGODB_INITIAL_PRIMARY_PORT_NUMBER=27017"
    echo "MONGODB_ADVERTISED_HOSTNAME=unicchat.mongodb"
    echo "MONGODB_ENABLE_JOURNAL=true"
  } > "$dir/mongo.env"
  
  # Генерируем mongo_creds.env
  {
    echo "MONGODB_ROOT_PASSWORD=$MONGODB_ROOT_PASSWORD"
    echo "MONGODB_USERNAME=$MONGODB_USERNAME"
    echo "MONGODB_PASSWORD=$MONGODB_PASSWORD"
    echo "MONGODB_DATABASE=$MONGODB_DATABASE"
  } > "$dir/mongo_creds.env"
  
  # Генерируем appserver.env
  {
    echo "DB_COLLECTIONS_PREFIX=unicchat_"
    echo "UNIC_SOLID_HOST=http://unicchat.tasker:8080"
    echo "PORT=3000"
    echo "DEPLOY_METHOD=docker"
  } > "$dir/appserver.env"
  
  # Генерируем appserver_creds.env
  {
    echo "MONGO_URL=mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@unicchat.mongodb:27017/$MONGODB_DATABASE?replicaSet=rs0"
    echo "MONGO_OPLOG_URL=mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@unicchat.mongodb:27017/local"
    echo "ROOT_URL=$ROOT_URL"
  } > "$dir/appserver_creds.env"
  
  # Генерируем logger.env
  {
    echo "# Logger API URL (internal)"
    echo "api.logger.url=http://unicchat.logger:8080/"
  } > "$dir/logger.env"
  
  # Запрашиваем названия БД для logger и vault
  echo -e "\n📊 Database Names:"
  ask_value "  Logger database name" "${LOGGER_DB:-logger_db}" "LOGGER_DB"
  ask_value "  Vault database name" "${VAULT_DB:-vault_db}" "VAULT_DB"
  
  # Сохраняем в конфиг файл
  {
    echo "LOGGER_DB=$LOGGER_DB"
    echo "VAULT_DB=$VAULT_DB"
  } >> "$CREDS_CONFIG_FILE"
  
  # Генерируем logger_creds.env
  {
    echo "# MongoDB connection for logger service"
    echo "MongoCS=\"mongodb://$LOGGER_USER:$LOGGER_PASSWORD_ENCODED@unicchat.mongodb:27017/$LOGGER_DB?directConnection=true&authSource=$LOGGER_DB&authMechanism=SCRAM-SHA-256\""
  } > "$dir/logger_creds.env"
  
  # Генерируем vault_creds.env
  {
    echo "# MongoDB connection for vault service"
    echo "MongoCS=\"mongodb://$VAULT_USER:$VAULT_PASSWORD_ENCODED@unicchat.mongodb:27017/$VAULT_DB?directConnection=true&authSource=$VAULT_DB&authMechanism=SCRAM-SHA-256\""
  } > "$dir/vault_creds.env"
  
  echo "✅ All env files generated successfully!"
}

# Функция для URL-декодирования
urldecode() {
  local string="${1}"
  string="${string//+/ }"
  printf '%b' "${string//%/\\x}"
}

setup_mongodb_users() {
  echo -e "\n🔐 Setting up MongoDB users for services…"
  local dir="single-server-install"
  
  # Проверяем что MongoDB запущен
  if ! docker ps | grep -q "unicchat.mongodb"; then
    echo "⚠️ MongoDB container is not running. Start services first (step 7)."
    return 1
  fi
  
  # Читаем root password из mongo_creds.env
  local mongo_creds_file="$dir/mongo_creds.env"
  if [ ! -f "$mongo_creds_file" ]; then
    echo "❌ File $mongo_creds_file not found. Run 'Prepare .env files and credentials' first."
    return 1
  fi
  
  local root_password=$(grep '^MONGODB_ROOT_PASSWORD=' "$mongo_creds_file" | cut -d '=' -f2- | tr -d '\r')
  local container="unicchat.mongodb"
  
  if [ -z "$root_password" ]; then
    echo "❌ MONGODB_ROOT_PASSWORD not found in $mongo_creds_file"
    return 1
  fi
  
  # Ждем пока MongoDB будет готов (упрощенная проверка)
  echo "⏳ Waiting for MongoDB to be ready..."
  local max_attempts=15
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if docker exec "$container" mongosh -u root -p "$root_password" --quiet --eval "db.adminCommand('ping')" 2>/dev/null | grep -q "ok.*1"; then
      echo "✅ MongoDB is ready"
      break
    fi
    attempt=$((attempt + 1))
    echo "  Attempt $attempt/$max_attempts..."
    sleep 2
  done
  
  if [ $attempt -eq $max_attempts ]; then
    echo "❌ MongoDB is not ready after $max_attempts attempts"
    echo "   Trying to continue anyway..."
  fi
  
  # Читаем credentials для logger из logger_creds.env
  local logger_creds_file="$dir/logger_creds.env"
  if [ -f "$logger_creds_file" ]; then
    local logger_mongocs=$(grep '^MongoCS=' "$logger_creds_file" | cut -d '=' -f2- | tr -d '\r' | sed 's/^"//;s/"$//')
    if [ -z "$logger_mongocs" ]; then
      echo "⚠️ MongoCS not found in logger_creds.env, skipping logger user"
    else
      # Извлекаем username, password и database из connection string: mongodb://user:pass@host/db
      # Убираем префикс mongodb://
      local creds_part=$(echo "$logger_mongocs" | sed 's|^mongodb://||' | cut -d '@' -f1)
      local host_part=$(echo "$logger_mongocs" | sed 's|^mongodb://||' | cut -d '@' -f2)
      local logger_user=$(echo "$creds_part" | cut -d ':' -f1)
      local logger_pass_encoded=$(echo "$creds_part" | cut -d ':' -f2-)
      # Извлекаем название БД из connection string (после @host/)
      local logger_db=$(echo "$host_part" | cut -d '/' -f2 | cut -d '?' -f1)
      # Если БД не указана, используем дефолтное значение
      logger_db=${logger_db:-logger_db}
      
      # Пароль может быть уже декодирован или закодирован
      local logger_pass
      if [[ "$logger_pass_encoded" == *%* ]]; then
        logger_pass=$(urldecode "$logger_pass_encoded")
      else
        logger_pass="$logger_pass_encoded"
      fi
      
      if [ -n "$logger_user" ] && [ -n "$logger_pass" ] && [ -n "$logger_db" ]; then
        echo "📝 Creating $logger_db and logger_user ($logger_user)..."
        echo "   Extracted user: $logger_user, database: $logger_db"
        
        # Создаем пользователя или обновляем пароль
        local temp_script=$(mktemp)
        cat > "$temp_script" <<EOF
use $logger_db
try {
  db.createUser({
    user: '$logger_user',
    pwd: '$logger_pass',
    roles: [{ role: 'readWrite', db: '$logger_db' }]
  })
  print('CREATED')
} catch(e) {
  if (e.code === 51003 || e.codeName === 'DuplicateKey' || e.message.includes('already exists')) {
    db.changeUserPassword('$logger_user', '$logger_pass')
    print('PASSWORD_UPDATED')
  } else {
    print('ERROR: ' + e.message)
    throw e
  }
}
EOF
        
        local create_output=$(timeout 30 docker exec -i "$container" mongosh -u root -p "$root_password" < "$temp_script" 2>&1)
        rm -f "$temp_script"
        
        # Проверяем авторизацию с этими credentials
        echo "   Testing authentication..."
        local auth_test=$(timeout 10 docker exec "$container" mongosh -u "$logger_user" -p "$logger_pass" --authenticationDatabase "$logger_db" "$logger_db" --eval "db.getName()" 2>&1)
        
        if echo "$create_output" | grep -qE "CREATED|PASSWORD_UPDATED" && echo "$auth_test" | grep -q "$logger_db"; then
          echo "✅ Logger user configured and verified"
        elif echo "$create_output" | grep -qE "CREATED|PASSWORD_UPDATED"; then
          echo "✅ Logger user configured (auth test: $(echo "$auth_test" | grep -E "$logger_db|Error|Authentication" | head -1))"
        else
          echo "⚠️ Logger user configuration failed"
          echo "   Output: $create_output"
        fi
      else
        echo "⚠️ Failed to extract logger credentials from connection string"
        echo "   User: '$logger_user', Pass: [hidden]"
      fi
    fi
  else
    echo "⚠️ logger_creds.env not found, skipping logger user creation"
  fi
  
      # Читаем credentials для vault из vault_creds.env
      local vault_env_file="$dir/vault_creds.env"
      if [ -f "$vault_env_file" ]; then
        local vault_mongocs=$(grep '^MongoCS=' "$vault_env_file" | cut -d '=' -f2- | tr -d '\r' | sed 's/^"//;s/"$//')
        if [ -z "$vault_mongocs" ]; then
          echo "⚠️ MongoCS not found in vault_creds.env, skipping vault user"
    else
      # Извлекаем username, password и database из connection string: mongodb://user:pass@host/db
      # Убираем префикс mongodb://
      local creds_part=$(echo "$vault_mongocs" | sed 's|^mongodb://||' | cut -d '@' -f1)
      local host_part=$(echo "$vault_mongocs" | sed 's|^mongodb://||' | cut -d '@' -f2)
      local vault_user=$(echo "$creds_part" | cut -d ':' -f1)
      local vault_pass_encoded=$(echo "$creds_part" | cut -d ':' -f2-)
      # Извлекаем название БД из connection string (после @host/)
      local vault_db=$(echo "$host_part" | cut -d '/' -f2 | cut -d '?' -f1)
      # Если БД не указана, используем дефолтное значение
      vault_db=${vault_db:-vault_db}
      
      # Пароль может быть уже декодирован или закодирован
      local vault_pass
      if [[ "$vault_pass_encoded" == *%* ]]; then
        vault_pass=$(urldecode "$vault_pass_encoded")
      else
        vault_pass="$vault_pass_encoded"
      fi
      
      if [ -n "$vault_user" ] && [ -n "$vault_pass" ] && [ -n "$vault_db" ]; then
        echo "📝 Creating $vault_db and vault_user ($vault_user)..."
        echo "   Extracted user: $vault_user, database: $vault_db"
        
        # Создаем пользователя или обновляем пароль
        local temp_script=$(mktemp)
        cat > "$temp_script" <<EOF
use $vault_db
try {
  db.createUser({
    user: '$vault_user',
    pwd: '$vault_pass',
    roles: [{ role: 'readWrite', db: '$vault_db' }]
  })
  print('CREATED')
} catch(e) {
  if (e.code === 51003 || e.codeName === 'DuplicateKey' || e.message.includes('already exists')) {
    db.changeUserPassword('$vault_user', '$vault_pass')
    print('PASSWORD_UPDATED')
  } else {
    print('ERROR: ' + e.message)
    throw e
  }
}
EOF
        
        local create_output=$(timeout 30 docker exec -i "$container" mongosh -u root -p "$root_password" < "$temp_script" 2>&1)
        rm -f "$temp_script"
        
        # Проверяем авторизацию с этими credentials
        echo "   Testing authentication..."
        local auth_test=$(timeout 10 docker exec "$container" mongosh -u "$vault_user" -p "$vault_pass" --authenticationDatabase "$vault_db" "$vault_db" --eval "db.getName()" 2>&1)
        
        if echo "$create_output" | grep -qE "CREATED|PASSWORD_UPDATED" && echo "$auth_test" | grep -q "$vault_db"; then
          echo "✅ Vault user configured and verified"
        elif echo "$create_output" | grep -qE "CREATED|PASSWORD_UPDATED"; then
          echo "✅ Vault user configured (auth test: $(echo "$auth_test" | grep -E "$vault_db|Error|Authentication" | head -1))"
        else
          echo "⚠️ Vault user configuration failed"
          echo "   Output: $create_output"
        fi
      else
        echo "⚠️ Failed to extract vault credentials from connection string"
        echo "   User: '$vault_user', Pass: [hidden]"
      fi
    fi
  else
        echo "⚠️ vault_creds.env not found, skipping vault user creation"
  fi
  
  echo "✅ MongoDB users configured."
}

setup_vault_secrets() {
  echo -e "\n🔐 Setting up Vault secrets for KBT service…"
  local dir="single-server-install"
  
  # Проверяем что Vault запущен
  local container="unicchat.vault"
  if ! docker ps | grep -q "$container"; then
    echo "⚠️ Vault container is not running. Start services first (step 7)."
    return 1
  fi
  
  # Читаем MONGO_URL из appserver_creds.env
  local appserver_creds_file="$dir/appserver_creds.env"
  if [ ! -f "$appserver_creds_file" ]; then
    echo "❌ File $appserver_creds_file not found. Run 'Prepare .env files and credentials' first."
    return 1
  fi
  
  local mongo_url=$(grep '^MONGO_URL=' "$appserver_creds_file" | cut -d '=' -f2- | tr -d '\r')
  if [ -z "$mongo_url" ]; then
    echo "❌ MONGO_URL not found in $appserver_creds_file"
    return 1
  fi
  
  # Проверяем наличие curl в контейнере и устанавливаем если нужно
  echo "🔧 Checking for curl in container..."
  if ! docker exec "$container" which curl >/dev/null 2>&1; then
    echo "   curl not found, installing..."
    # Пробуем установить с правами root
    docker exec -u root "$container" sh -c "apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1" 2>&1 || \
    docker exec -u root "$container" sh -c "apk update -q && apk add -q curl >/dev/null 2>&1" 2>&1 || \
    docker exec "$container" sh -c "apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1" 2>&1 || \
    docker exec "$container" sh -c "apk update -q && apk add -q curl >/dev/null 2>&1" 2>&1 || {
      echo "⚠️ Failed to install curl in container"
      echo "   Trying alternative: wget..."
      # Пробуем использовать wget если он есть
      if docker exec "$container" which wget >/dev/null 2>&1; then
        echo "✅ wget found, will use it instead"
        USE_WGET=true
      else
        echo "⚠️ Please ask developer to include curl or wget in the Vault image"
        return 1
      fi
    }
    if [ "${USE_WGET:-false}" != "true" ]; then
      echo "✅ curl installed"
    fi
  fi
  
  # Vault доступен внутри контейнера на localhost:80
  local vault_url="http://localhost:80"
  local token_id="0f8e160416b94225a73f86ac23b9118b"
  local username="KBTservice"
  
  # Определяем команду для HTTP запросов
  local http_cmd="curl"
  if [ "${USE_WGET:-false}" = "true" ]; then
    http_cmd="wget -qO-"
  fi
  
  echo "⏳ Waiting for Vault to be ready..."
  local max_attempts=15
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if docker exec "$container" sh -c "$http_cmd -s -f '$vault_url/api/token/$token_id?username=$username'" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    echo "  Attempt $attempt/$max_attempts..."
    sleep 2
  done
  
  if [ $attempt -eq $max_attempts ]; then
    echo "⚠️ Vault is not ready, trying to continue anyway..."
  fi
  
  # Получаем токен внутри контейнера
  echo "📝 Getting Vault token..."
  if [ "${USE_WGET:-false}" = "true" ]; then
    local token_response=$(docker exec "$container" sh -c "wget -qO- --method=GET '$vault_url/api/token/$token_id?username=$username'" 2>&1)
  else
    local token_response=$(docker exec "$container" sh -c "curl -s -X 'GET' '$vault_url/api/token/$token_id?username=$username'" 2>&1)
  fi
  
  # Пробуем разные форматы ответа
  local token=""
  if echo "$token_response" | grep -q '"token"'; then
    token=$(echo "$token_response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
  elif echo "$token_response" | grep -q 'token'; then
    token=$(echo "$token_response" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  else
    # Возможно токен возвращается как plain text
    token=$(echo "$token_response" | tr -d '\n\r" ')
  fi
  
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "⚠️ Failed to get token from Vault."
    echo "   Response: $token_response"
    echo "   Skipping Vault secrets setup"
    return 1
  fi
  
  echo "✅ Token obtained"
  
  # Создаем секрет внутри контейнера
  echo "📝 Creating KBTConfigs secret in Vault..."
  local secret_payload=$(cat <<EOF
{
  "id": "KBTConfigs",
  "name": "KBTConfigs",
  "type": "Password",
  "data": "All info in META",
  "metadata": {
    "MongoCS": "$mongo_url",
    "MinioHost": "PLACEHOLDER_MINIO_HOST",
    "MinioUser": "PLACEHOLDER_MINIO_USER",
    "MinioPass": "PLACEHOLDER_MINIO_PASS"
  },
  "tags": ["KB", "Tasker", "Mongo", "Minio"],
  "expiresAt": "2030-12-31T23:59:59.999Z"
}
EOF
)
  
  # Выполняем POST запрос внутри контейнера
  echo "   Sending POST request to /api/Secrets..."
  # Создаем временный файл с payload внутри контейнера
  local temp_payload=$(mktemp)
  echo "$secret_payload" > "$temp_payload"
  docker cp "$temp_payload" "$container:/tmp/payload.json" >/dev/null 2>&1
  rm -f "$temp_payload"
  
  # Выполняем запрос с таймаутом
  local secret_response=""
  if [ "${USE_WGET:-false}" = "true" ]; then
    secret_response=$(timeout 30 docker exec "$container" sh -c "wget -qO- --method=POST \
      --header='Authorization: Bearer $token' \
      --header='accept: text/plain' \
      --header='Content-Type: application/json' \
      --body-file=/tmp/payload.json \
      '$vault_url/api/Secrets' && echo '200'" 2>&1) || secret_response="TIMEOUT"
  else
    secret_response=$(timeout 30 docker exec "$container" sh -c "curl -s --max-time 25 -w '\n%{http_code}' -X 'POST' \
      '$vault_url/api/Secrets' \
      -H 'Authorization: Bearer $token' \
      -H 'accept: text/plain' \
      -H 'Content-Type: application/json' \
      -d @/tmp/payload.json" 2>&1) || secret_response="TIMEOUT"
  fi
  
  # Удаляем временный файл из контейнера
  docker exec "$container" rm -f /tmp/payload.json >/dev/null 2>&1 || true
  
  if [ "$secret_response" = "TIMEOUT" ]; then
    echo "⚠️ Request timeout. Secret may or may not have been created."
    return 0
  fi
  
  local http_code=$(echo "$secret_response" | tail -n1)
  local response_body=$(echo "$secret_response" | head -n-1)
  
  echo "   HTTP response code: $http_code"
  
  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    echo "✅ Vault secret KBTConfigs created successfully"
  else
    echo "⚠️ Failed to create Vault secret. HTTP code: $http_code"
    if [ -n "$response_body" ]; then
      echo "   Response: $response_body"
    fi
  fi
}

login_yandex() {
  echo -e "\n🔑 Logging into Yandex Container Registry…"
  docker login --username oauth \
    --password y0_AgAAAAB3muX6AATuwQAAAAEawLLRAAB9TQHeGyxGPZXkjVDHF1ZNJcV8UQ \
    cr.yandex
  echo "✅ Logged in."
}

create_network() {
  echo -e "\n🌐 Creating Docker network…"
  
  if docker network inspect unicchat-network >/dev/null 2>&1; then
    echo "✅ Network 'unicchat-network' already exists."
  else
    docker network create unicchat-network
    echo "✅ Network 'unicchat-network' created successfully."
  fi
}


start_unicchat() {
  echo -e "\n🚀 Starting UnicChat services…"
  local dir="single-server-install"
  
  # Проверяем что сеть существует
  if ! docker network inspect unicchat-network >/dev/null 2>&1; then
    echo "⚠️ Network 'unicchat-network' does not exist. Creating it now..."
    docker network create unicchat-network
  fi
  
  # Экспортируем переменные для docker-compose
  export DOMAIN
  
  # Запускаем основные сервисы
  (cd "$dir" && DOMAIN="$DOMAIN" docker_compose -f unicchat.yml up -d)
  
  echo "✅ UnicChat services started (MongoDB, Tasker, Appserver, Vault, Logger)."
}

restart_unicchat() {
  echo -e "\n🔄 Restarting all UnicChat services…"
  local dir="single-server-install"
  
  # Экспортируем переменные для docker-compose
  export DOMAIN
  
  # Полный перезапуск всех сервисов
  (cd "$dir" && DOMAIN="$DOMAIN" docker_compose -f unicchat.yml down)
  (cd "$dir" && DOMAIN="$DOMAIN" docker_compose -f unicchat.yml up -d)
  
  echo "✅ All UnicChat services restarted."
}

update_site_url() {
  echo -e "\n📝 Updating Site_Url in MongoDB…"
  local dir="single-server-install"
  local env_file="$dir/mongo_creds.env"
  local container="unicchat.mongodb"
  local pwd=$(grep -E '^MONGODB_ROOT_PASSWORD=' "$env_file" | cut -d '=' -f2 | tr -d '\r')
  local url="https://$DOMAIN"
  if [ "$DOMAIN" = "localhost" ]; then
    url="http://localhost:8080"
  fi
  
  # Ждем пока MongoDB будет готов
  echo "⏳ Waiting for MongoDB to be ready..."
  sleep 5
  
  docker exec "$container" mongosh -u root -p "$pwd" --quiet --eval "db.getSiblingDB('unicchat_db').rocketchat_settings.updateOne({_id:'Site_Url'},{\$set:{value:'$url'}})" || \
    echo "⚠️ Could not update Site_Url (MongoDB might not be ready yet)"
  docker exec "$container" mongosh -u root -p "$pwd" --quiet --eval "db.getSiblingDB('unicchat_db').rocketchat_settings.updateOne({_id:'Site_Url'},{\$set:{packageValue:'$url'}})" || \
    echo "⚠️ Could not update packageValue (MongoDB might not be ready yet)"
  echo "✅ Site_Url update attempted."
}

cleanup_all() {
  echo -e "\n🗑️  Cleaning up UnicChat containers, volumes and images…"
  local dir="single-server-install"
  
  # Останавливаем и удаляем контейнеры через docker-compose
  echo "🛑 Stopping and removing containers..."
  (cd "$dir" && docker_compose -f unicchat.yml down -v 2>/dev/null || true)
  
  # Удаляем контейнеры по именам (на случай если docker-compose не сработал)
  for container in unicchat.mongodb unicchat.tasker unicchat.appserver unicchat.vault unicchat.logger; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
      echo "  Removing container: $container"
      docker stop "$container" 2>/dev/null || true
      docker rm "$container" 2>/dev/null || true
    fi
  done
  
  # Удаляем volumes
  echo "🗑️  Removing volumes..."
  for volume in single-server-install_mongodb_data single-server-install_chat_data single-server-install_vault-data; do
    if docker volume ls --format '{{.Name}}' | grep -q "^${volume}$"; then
      echo "  Removing volume: $volume"
      docker volume rm "$volume" 2>/dev/null || true
    fi
  done
  
  # Удаляем сеть
  echo "🌐 Removing network..."
  if docker network inspect unicchat-network >/dev/null 2>&1; then
    docker network rm unicchat-network 2>/dev/null || true
    echo "  Network 'unicchat-network' removed"
  fi
  
  # Удаляем images
  echo "🖼️  Removing images..."
  for image in cr.yandex/crps5m51hmah43pmfb23/mongodb:4.4 \
               cr.yandex/crpi5ll6mqcn793fvu9i/unicchatkbasetasker:prod \
               cr.yandex/crpvpl7g37r2id3i2qe5/unic_chat_appserver:prod.6-2.1.81-beta.5 \
               cr.yandex/crpi5ll6mqcn793fvu9i/unic/unicvault:prod \
               cr.yandex/crpi5ll6mqcn793fvu9i/unic/uniclogger:prod; do
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
      echo "  Removing image: $image"
      docker rmi "$image" 2>/dev/null || true
    fi
  done
  
  echo "✅ Cleanup completed!"
}

auto_setup() {
  echo -e "\n⚙️ Running full automatic setup…"
  install_deps
  check_avx
  setup_domain
  create_network
  prepare_unicchat
  login_yandex
  start_unicchat
  echo -e "\n⏳ Waiting for MongoDB to be ready..."
  sleep 15
  setup_mongodb_users
  echo -e "\n⏳ Waiting for services to start..."
  sleep 10
  setup_vault_secrets
#  update_site_url
  echo -e "\n🎉 UnicChat setup complete!"
  if [ "$DOMAIN" = "localhost" ]; then
    echo -e "🌐 Access your instance at: http://localhost:8080"
  else
    echo -e "🌐 Access your instance at: https://$DOMAIN"
  fi
}

main_menu() {
  echo -e "\n✨ Welcome to UnicChat Installer"
  echo -e "✅ Domain: $DOMAIN\n"
  while true; do
    cat <<MENU
 [1]  Install dependencies
 [2]  Check AVX support
 [3]  Setup domain and check DNS
 [4]  Create Docker network (unicchat-network)
 [5]  Prepare .env files and credentials
 [6]  Login to Yandex registry
 [7]  Start UnicChat containers
 [8]  Setup MongoDB users (separate DB per service)
 [9]  Setup Vault secrets for KBT service
[10]  Restart all UnicChat services
[99]  🚀 Full automatic setup
[100] 🗑️  Cleanup (remove containers, volumes, images)
 [0]  Exit
MENU
    read -rp "👉 Select an option: " choice
    case $choice in
      1) install_deps ;;
      2) check_avx ;;
      3) setup_domain ;;
      4) create_network ;;
      5) prepare_unicchat ;;
      6) login_yandex ;;
      7) start_unicchat ;;
      8) setup_mongodb_users ;;
      9) setup_vault_secrets ;;
      10) restart_unicchat ;;
      100) cleanup_all ;;
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
