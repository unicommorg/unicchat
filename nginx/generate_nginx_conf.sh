#!/bin/bash

# Проверяем, существует ли файл с доменом
DOMAIN_FILE="domain.txt"
if [ ! -f "$DOMAIN_FILE" ]; then
    echo "Ошибка: файл $DOMAIN_FILE не найден"
    exit 1
fi

# Читаем доменное имя из файла
DOMAIN=$(cat "$DOMAIN_FILE" | tr -d '\n')

# Проверяем, что домен не пустой
if [ -z "$DOMAIN" ]; then
    echo "Ошибка: доменное имя не указано в файле $DOMAIN_FILE"
    exit 1
fi

# Определяем имя выходного файла
OUTPUT_FILE="${DOMAIN}"

# Генерируем конфигурацию Nginx
cat > "$OUTPUT_FILE" <<EOF
# Конфигурация сгенерирована автоматически для домена $DOMAIN

upstream internal {
    server 127.0.0.1:8080;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    client_max_body_size 200M;

    error_log /var/log/nginx/${DOMAIN}.error.log;
    access_log /var/log/nginx/${DOMAIN}.access.log;

    # CORS-заголовки
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Credentials true;
    add_header "Access-Control-Allow-Methods" "GET, POST, OPTIONS, HEAD";
    add_header "Access-Control-Allow-Headers" "Authorization, Origin, X-Requested-With, Content-Type, Accept";

    # Preflight-запросы
    if (\$request_method = OPTIONS) {
        return 204;
    }

    location / {
        proxy_pass http://internal;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Nginx-Proxy true;

        proxy_redirect off;
    }

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    listen 80;
    server_name $DOMAIN;

    # HTTP перенаправление на HTTPS
    return 301 https://\$host\$request_uri;
}
EOF

echo "Конфигурация Nginx успешно сгенерирована в файле $OUTPUT_FILE"
