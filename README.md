## Инструкция по установке UnicChat

###### версия free-1.0.0, версия документа 1.0

### Подготовка окружения

##### Минимальные требования на (20 пользователей)

* Сервер приложения и БД

```
CPU 4 cores 1.7ghz, с набором инструкций FMA3, SSE4.2, AVX 2.0;
RAM 8 Gb;
150 Gb HDD\SDD;
```

##### Рекомендуемые требования на (20-50 пользователей)

* Сервер приложения

```
CPU 4 cores 1.7ghz, с набором инструкций FMA3, SSE4.2, AVX 2.0;
RAM 8 Gb;
200 Gb HDD\SDD
```

* Сервер БД

```
CPU 4 cores 1.7ghz, с набором инструкций FMA3, SSE4.2, AVX 2.0;
RAM 8 Gb;
100 Gb HDD\SDD
```

##### Сторонние зависимости

1. Установить `docker` и `docker-compose `
2. Установить `nginx`

### Установка и настройка mongodb

1. Запустить mongodb, например, используя yml файл ниже, предварительно указав ваш пароль `root` в
   параметре `{YOUR_ROOT_PASSWORD}`

```dockerfile 
version: "3"
services:
  mongodb:
    image: docker.io/bitnami/mongodb:${MONGODB_VERSION:-4.4}
    container_name: unic.chat.free.db.mongo
    restart: on-failure
    volumes:
      - mongodb_data:/bitnami/mongodb
    environment:
      MONGODB_REPLICA_SET_MODE: primary
      MONGODB_REPLICA_SET_NAME: ${MONGODB_REPLICA_SET_NAME:-rs0}
      MONGODB_REPLICA_SET_KEY: ${MONGODB_REPLICA_SET_KEY:-rs0key}
      MONGODB_PORT_NUMBER: ${MONGODB_PORT_NUMBER:-27017}
      MONGODB_INITIAL_PRIMARY_HOST: ${MONGODB_INITIAL_PRIMARY_HOST:-mongodb}
      MONGODB_INITIAL_PRIMARY_PORT_NUMBER: ${MONGODB_INITIAL_PRIMARY_PORT_NUMBER:-27017}
      MONGODB_ADVERTISED_HOSTNAME: ${MONGODB_ADVERTISED_HOSTNAME:-mongodb}
      MONGODB_ENABLE_JOURNAL: ${MONGODB_ENABLE_JOURNAL:-true}
      MONGODB_ROOT_PASSWORD: {YOUR_ROOT_PASSWORD}
    networks:
      - unic-chat-free

networks:
  unic-chat-free:
    driver: bridge

volumes:
  mongodb_data: { driver: local }
```

### Создать базу и пользователя для подключения к базе

1. Подключиться к mongodb
2. Выполнить скрипты создания базы и пользователя, указать преварительно параметры:
    3. `{DB_NAME}` - название базы;
    4. `{UNICCHAT_USERNAME}` - пользователь, под которым будет подключаться приложение;
    5. `{UNICCHAT_PASSWORD}` - пароль пользователя приложения;

```micronaut-mongodb-json
use {
  DB_NAME
};

db.createUser(
{user: "{UNICCHAT_USERNAME}", pwd: "{UNICCHAT_PASSWORD}", roles: [
{role: "readWrite", db: "local"},
{role: "readWrite", db: "{DB_NAME}"},
{role: "dbAdmin", db: "{DB_NAME}"},
{role: "clusterMonitor", db: "admin"}
]
}
);

```

### Настройка nginx

Пример конфигурации сайта для nginx. Значения в которые необходимо указать:

- {PORT} - порт на котором будет запущен UnicChat на сервере приложения;
- {DOMAIN} - ваш домен

```
upstream free {
server 127.0.0.1:{PORT};
}

server {
server_name {DOMAIN} www.{DOMAIN};

    client_max_body_size 200M;

    error_log /var/log/nginx/{DOMAIN}.error.log;
    access_log /var/log/nginx/{DOMAIN}.access.log;

    location / {
        proxy_pass http://free;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Nginx-Proxy true;

        proxy_redirect off;
    }

    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/{DOMAIN}/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/{DOMAIN}/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}

server {
if ($host = {DOMAIN}) {
return 301 https://$host$request_uri;
} 
    server_name {DOMAIN} www.{DOMAIN};
    
    listen 80;
    return 404; # managed by Certbot
}
```

### Установка UnicChat

1. Заполнить параметы в yml файле
    2. `{PORT}` - порт, на котром будет запущено приложение (должен быть тот же что был указан для nginx)
    3. `{DB_NAME}` - название базы;
    4. `{UNICCHAT_USERNAME}` - пользователь, под которым будет подключаться приложение;
    5. `{UNICCHAT_PASSWORD}` - пароль пользователя приложения;

```dockerfile
version: "3"
services:
  unic.chat.free:
    container_name: unic.chat.appserver.free
    image: index.docker.io/unicommhub/unicchat_free:1.0.0
    restart: on-failure
    environment:
      -  MONGO_URL=mongodb://{UNICCHAT_USERNAME}:{UNICCHAT_PASSWORD}@mongodb:27017/{DB_NAME}?replicaSet=rs0
      -  MONGO_OPLOG_URL=mongodb://{UNICCHAT_USERNAME}:{UNICCHAT_PASSWORD}@mongodb:27017/local
      -  ROOT_URL=http://localhost:{PORT}
      -  PORT={PORT}
      -  DEPLOY_METHOD=docker
    ports:
      - {PORT}:{PORT}
    networks:
      - unic-chat-free

networks:
  unic-chat-free:
    driver: bridge
```

2. Запустить контейнер, например, командой `docker-compose -f {YML_FILE} up -d`
3. После запуска приложения, открыть веб-интерфейс приложения по адресу `http://localhost:{PORT}` и создать первого
   пользователя-администратора, заполнив параметры

* `Name` - Имя пользователя, которое будет отображаться в чате;
* `Username` - Логин пользователя, который вы будете указывать для авторизации;
* `Email` - Действующая почта, используется для восстановления
* `Organization Name` - Краткое название вашей организации латинскими буквами без пробелов и спец. символов,
  используется для регистрации push уведомлений. Может быть указан позже;
* `Organization ID` - Идентификатор вашей организации, используется для подключения к push серверу. Может быть указан
  позже. Для получения ID необходимо написать запрос с указанием значения в Organization Name на почту
  support@unicomm.pro;
* `Password` - пароль вашего пользователя;
* `Confirm your password` - подтверждение пароля;

4. После создания пользователя, авторизоваться в веб-интерфейсе с использованием ранее указанных параметров.
5. Для включения пушей, перейти в раздел Администрирование - Push. Включить использование шлюза и указать адрес
   шлюза https://push1.unic.chat
6. Перейти в раздел Администрирование - Organization, убедиться что поля заполнены в соответсвии с п.2
7. Настройка завершена.

### Клиентские приложения

Репозиторий для клиентских приложений: https://github.com/unicommorg/unic.chat.client.releases/releases

### Документация
