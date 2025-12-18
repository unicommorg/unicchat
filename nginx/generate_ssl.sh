#!/usr/bin/env bash
#
# Скрипт для управления SSL сертификатами и nginx
# Использует данные из unicchat_config.txt
#

set -euo pipefail

# Получаем данные из unicchat_config.txt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../unicchat_config.txt"

# Функция для выбора команды docker compose
docker_compose() {
    if command -v docker compose >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        echo "❌ docker compose not found. Установите Docker и Docker Compose."
        exit 1
    fi
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ Файл unicchat_config.txt не найден: $CONFIG_FILE"
        return 1
    fi

    DOMAIN=$(grep '^DOMAIN=' "$CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r' | tr -d ' ')
    EMAIL=$(grep '^EMAIL=' "$CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r' | tr -d ' ')

    if [ -z "$DOMAIN" ]; then
        echo "❌ DOMAIN не найден в unicchat_config.txt"
        return 1
    fi

    if [ -z "$EMAIL" ]; then
        echo "❌ EMAIL не найден в unicchat_config.txt"
        echo "   Добавьте строку EMAIL=your@email.com в файл $CONFIG_FILE"
        return 1
    fi

    return 0
}

generate_ssl() {
    if [[ $EUID -ne 0 ]]; then
        echo "🚫 This function must be run as root or with sudo."
        return 1
    fi

    load_config || return 1
    cd "$SCRIPT_DIR"

    echo "🔐 Генерация SSL сертификата для домена: $DOMAIN"
    echo "📧 Email: $EMAIL"
    echo ""

    # Создаем необходимые директории
    mkdir -p ssl www
    chmod 755 ssl www

    # Скачиваем options-ssl-nginx.conf если его нет
    if [ ! -f "ssl/options-ssl-nginx.conf" ]; then
        echo "📥 Скачивание options-ssl-nginx.conf..."
        curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > ssl/options-ssl-nginx.conf
        echo "   ✅ Файл скачан"
    fi

    # Генерируем DH parameters если их нет
    if [ ! -f "ssl/ssl-dhparams.pem" ]; then
        echo "⏳ Генерация DH parameters (это может занять несколько минут)..."
        docker run --rm \
          -v "$(pwd)/ssl:/etc/letsencrypt" \
          alpine:latest \
          sh -c "apk add --no-cache openssl && openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048"
        echo "   ✅ DH parameters сгенерированы"
    fi

    # Проверяем что сеть существует
    if ! docker network inspect unicchat-network >/dev/null 2>&1; then
        echo "🌐 Создание сети unicchat-network..."
        docker network create unicchat-network
        echo "   ✅ Сеть создана"
    fi

    # Останавливаем nginx если запущен (нужен свободный порт 80)
    echo "🛑 Остановка nginx (если запущен) для освобождения порта 80..."
    docker stop unicchat.nginx 2>/dev/null || true
    docker rm unicchat.nginx 2>/dev/null || true
    sleep 2

    # Проверяем что порт 80 свободен
    if ss -tuln 2>/dev/null | grep -q ':80 ' || netstat -tuln 2>/dev/null | grep -q ':80 '; then
        echo "⚠️ Порт 80 все еще занят. Проверьте что его использует:"
        ss -tulpn 2>/dev/null | grep ':80 ' || netstat -tulpn 2>/dev/null | grep ':80 ' || true
        echo ""
        read -rp "Продолжить anyway? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            echo "❌ Отменено"
            return 1
        fi
    fi

    # Генерируем SSL сертификат через standalone режим
    echo "🔐 Генерация SSL сертификата через Let's Encrypt (standalone режим)..."
    echo "   Certbot временно будет слушать на порту 80"
    echo ""

    docker run --rm \
      --network unicchat-network \
      -p 80:80 \
      -p 443:443 \
      -v "$(pwd)/ssl:/etc/letsencrypt" \
      certbot/certbot certonly \
      --standalone \
      --preferred-challenges http \
      --email "$EMAIL" \
      --agree-tos \
      --no-eff-email \
      --non-interactive \
      --verbose \
      -d "$DOMAIN" || {
        echo ""
        echo "❌ Не удалось получить SSL сертификат"
        echo ""
        echo "⚠️ Проверьте:"
        echo "   1. Домен указывает на IP сервера: dig $DOMAIN +short"
        echo "   2. Порт 80 свободен и доступен извне"
        echo "   3. Firewall разрешает входящие соединения на порт 80"
        echo "   4. Cloud provider firewall/security groups открыты для порта 80"
        echo ""
        return 1
      }

    echo ""
    echo "✅ SSL сертификат успешно получен!"
    echo ""

    # Обновляем конфигурацию nginx с доменом (полная конфигурация с SSL)
    echo "📝 Обновление конфигурации nginx (полная конфигурация с SSL)..."
    sed "s/\${DOMAIN}/$DOMAIN/g" config/nginx.conf.template > config/nginx.conf
    echo "   ✅ Конфигурация обновлена"
    echo ""

    # Запускаем nginx с SSL
    echo "🌐 Запуск nginx с SSL..."
    docker_compose up -d nginx
    sleep 3

    # Проверяем что nginx запустился
    if docker ps | grep -q "unicchat.nginx"; then
        echo "   ✅ Nginx запущен"
        
        # Проверяем конфигурацию
        if docker exec unicchat.nginx nginx -t 2>&1 | grep -q "successful"; then
            echo "   ✅ Конфигурация nginx корректна"
        else
            echo "   ⚠️ Ошибка в конфигурации nginx"
            docker exec unicchat.nginx nginx -t
        fi
    else
        echo "   ❌ Nginx не запустился. Проверьте логи: docker logs unicchat.nginx"
        return 1
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "✅ Готово! SSL сертификат установлен и nginx запущен с SSL."
    echo ""
    echo "📁 Расположение сертификатов:"
    echo "   $(pwd)/ssl/live/$DOMAIN/"
    echo ""
    echo "🌐 Проверьте работу:"
    echo "   curl https://$DOMAIN"
    echo ""
}

start_nginx() {
    if [[ $EUID -ne 0 ]]; then
        echo "🚫 This function must be run as root or with sudo."
        return 1
    fi

    load_config
    cd "$SCRIPT_DIR"

    echo "🌐 Запуск nginx..."

    # Проверяем что сеть существует
    if ! docker network inspect unicchat-network >/dev/null 2>&1; then
        echo "🌐 Создание сети unicchat-network..."
        docker network create unicchat-network
    fi

    # Обновляем конфигурацию если сертификат есть
    if [ -f "ssl/live/$DOMAIN/fullchain.pem" ]; then
        echo "📝 Обновление конфигурации nginx с SSL..."
        sed "s/\${DOMAIN}/$DOMAIN/g" config/nginx.conf.template > config/nginx.conf
    else
        echo "⚠️ SSL сертификат не найден. Используется временная конфигурация."
        sed "s/\${DOMAIN}/$DOMAIN/g" config/nginx-init.conf > config/nginx.conf
    fi

    docker_compose up -d nginx
    sleep 3

    if docker ps | grep -q "unicchat.nginx"; then
        echo "   ✅ Nginx запущен"
        if docker exec unicchat.nginx nginx -t 2>&1 | grep -q "successful"; then
            echo "   ✅ Конфигурация nginx корректна"
        else
            echo "   ⚠️ Ошибка в конфигурации nginx"
            docker exec unicchat.nginx nginx -t
        fi
    else
        echo "   ❌ Nginx не запустился. Проверьте логи: docker logs unicchat.nginx"
        return 1
    fi
    echo ""
}

stop_nginx() {
    if [[ $EUID -ne 0 ]]; then
        echo "🚫 This function must be run as root or with sudo."
        return 1
    fi

    cd "$SCRIPT_DIR"
    echo "🛑 Остановка nginx..."
    docker_compose stop nginx 2>/dev/null || docker stop unicchat.nginx 2>/dev/null || true
    echo "   ✅ Nginx остановлен"
    echo ""
}

restart_nginx() {
    if [[ $EUID -ne 0 ]]; then
        echo "🚫 This function must be run as root or with sudo."
        return 1
    fi

    load_config
    cd "$SCRIPT_DIR"

    echo "🔄 Перезапуск nginx..."

    # Обновляем конфигурацию
    if [ -f "ssl/live/$DOMAIN/fullchain.pem" ]; then
        sed "s/\${DOMAIN}/$DOMAIN/g" config/nginx.conf.template > config/nginx.conf
    else
        sed "s/\${DOMAIN}/$DOMAIN/g" config/nginx-init.conf > config/nginx.conf
    fi

    docker restart unicchat.nginx 2>/dev/null || docker_compose restart nginx
    sleep 2

    if docker ps | grep -q "unicchat.nginx"; then
        echo "   ✅ Nginx перезапущен"
    else
        echo "   ⚠️ Nginx не запустился. Проверьте логи"
    fi
    echo ""
}

status() {
    cd "$SCRIPT_DIR"
    load_config

    echo "📊 Статус сервисов:"
    echo ""

    # Статус nginx
    if docker ps | grep -q "unicchat.nginx"; then
        echo "✅ Nginx: запущен"
        docker ps | grep unicchat.nginx
    else
        echo "❌ Nginx: остановлен"
    fi
    echo ""

    # Статус certbot
    if docker ps | grep -q "unicchat.certbot"; then
        echo "✅ Certbot: запущен"
    else
        echo "⚠️ Certbot: остановлен"
    fi
    echo ""

    # Проверка SSL сертификата
    if [ -f "ssl/live/$DOMAIN/fullchain.pem" ]; then
        echo "✅ SSL сертификат: найден"
        echo "   Путь: ssl/live/$DOMAIN/"
        if command -v openssl >/dev/null 2>&1; then
            echo "   Срок действия:"
            openssl x509 -in "ssl/live/$DOMAIN/fullchain.pem" -noout -dates 2>/dev/null | sed 's/^/      /' || true
        fi
    else
        echo "❌ SSL сертификат: не найден"
    fi
    echo ""

    # Проверка портов
    echo "🔌 Прослушиваемые порты:"
    ss -tuln 2>/dev/null | grep -E ':(80|443)' || netstat -tuln 2>/dev/null | grep -E ':(80|443)' || echo "   Порты 80/443 не слушаются"
    echo ""
}

logs_nginx() {
    cd "$SCRIPT_DIR"
    echo "📋 Логи nginx (последние 50 строк):"
    echo ""
    docker logs --tail 50 unicchat.nginx 2>&1 || echo "Контейнер nginx не найден"
    echo ""
}

logs_certbot() {
    cd "$SCRIPT_DIR"
    echo "📋 Логи certbot (последние 50 строк):"
    echo ""
    docker logs --tail 50 unicchat.certbot 2>&1 || echo "Контейнер certbot не найден"
    echo ""
}

test_config() {
    if [[ $EUID -ne 0 ]]; then
        echo "🚫 This function must be run as root or with sudo."
        return 1
    fi

    cd "$SCRIPT_DIR"
    if docker ps | grep -q "unicchat.nginx"; then
        echo "🔍 Проверка конфигурации nginx:"
        docker exec unicchat.nginx nginx -t
    else
        echo "❌ Nginx не запущен"
    fi
    echo ""
}

generate_config() {
    load_config || return 1
    cd "$SCRIPT_DIR"

    echo "📝 Генерация конфигурации nginx..."
    echo "   Домен: $DOMAIN"
    echo ""

    # Проверяем наличие SSL сертификата
    if [ -f "ssl/live/$DOMAIN/fullchain.pem" ]; then
        echo "✅ SSL сертификат найден. Генерирую полную конфигурацию с SSL..."
        sed "s/\${DOMAIN}/$DOMAIN/g" config/nginx.conf.template > config/nginx.conf
        echo "   ✅ Конфигурация с SSL создана: config/nginx.conf"
    else
        echo "⚠️ SSL сертификат не найден. Генерирую временную конфигурацию (только HTTP)..."
        sed "s/\${DOMAIN}/$DOMAIN/g" config/nginx-init.conf > config/nginx.conf
        echo "   ✅ Временная конфигурация создана: config/nginx.conf"
    fi
    echo ""

    # Показываем что было заменено
    echo "📋 Замены в конфигурации:"
    echo "   \${DOMAIN} → $DOMAIN"
    echo ""

    # Показываем путь к сертификатам (если есть)
    if [ -f "ssl/live/$DOMAIN/fullchain.pem" ]; then
        echo "📁 Используемые сертификаты:"
        echo "   SSL cert: ssl/live/$DOMAIN/fullchain.pem"
        echo "   SSL key:  ssl/live/$DOMAIN/privkey.pem"
        echo ""
    fi

    # Показываем upstream
    echo "🔗 Upstream сервер:"
    grep -A 1 "upstream internal" config/nginx.conf | grep "server" | sed 's/^/   /'
    echo ""

    echo "💡 Для применения конфигурации перезапустите nginx (опция 4)"
    echo ""
}

main_menu() {
    # Загружаем конфигурацию один раз при запуске меню
    if [ -f "$CONFIG_FILE" ]; then
        DOMAIN=$(grep '^DOMAIN=' "$CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r' | tr -d ' ')
        EMAIL=$(grep '^EMAIL=' "$CONFIG_FILE" | cut -d '=' -f2- | tr -d '\r' | tr -d ' ')
    else
        DOMAIN=""
        EMAIL=""
    fi
    
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔐 Управление SSL и Nginx"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        if [ -n "$DOMAIN" ]; then
            echo "📋 Конфигурация:"
            echo "   Домен: $DOMAIN"
            if [ -n "$EMAIL" ]; then
                echo "   Email: $EMAIL"
            else
                echo "   Email: не указан (будет запрошен при генерации SSL)"
            fi
            echo ""
        else
            echo "⚠️  Файл unicchat_config.txt не найден или DOMAIN не указан"
            echo ""
        fi

        cat <<MENU
 [1] 🔐 Генерация SSL сертификата (Let's Encrypt)
 [2] 📝 Генерация/обновление конфигурации nginx
 [3] 🌐 Запуск nginx
 [4] 🛑 Остановка nginx
 [5] 🔄 Перезапуск nginx
 [6] 📊 Статус сервисов
 [7] 📋 Логи nginx
 [8] 📋 Логи certbot
 [9] 🔍 Проверка конфигурации nginx
 [0] 🚪 Выход
MENU
        echo ""
        read -rp "👉 Выберите опцию: " choice
        echo ""

        case $choice in
            1) 
                generate_ssl 
                ;;
            2) 
                if [ -z "$DOMAIN" ]; then
                    load_config
                fi
                generate_config 
                ;;
            3) start_nginx ;;
            4) stop_nginx ;;
            5) restart_nginx ;;
            6) status ;;
            7) logs_nginx ;;
            8) logs_certbot ;;
            9) test_config ;;
            0) echo "👋 До свидания!" && exit 0 ;;
            *) echo "❌ Неверный выбор. Нажмите Enter для продолжения..." && read ;;
        esac

        if [ "$choice" != "0" ]; then
            echo ""
            read -rp "Нажмите Enter для продолжения..."
        fi
    done
}

# Запуск меню
main_menu
