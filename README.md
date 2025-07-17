# Инструкция по установке корпоративного мессенджера для общения и командной работы UnicChat

###### Версия 6-2.1.70, версия документа 1.7

## Оглавление
<!-- TOC -->
  * [Инструкция по установке корпоративного мессенджера для общения и командной работы UnicChat](#инструкция-по-установке-корпоративного-мессенджера-для-общения-и-командной-работы-unicchat)
    * [Оглавление](#оглавление)
    * [Архитектура установки](#архитектура-установки)
    * [Шаг 1. Подготовка окружения](#шаг-1-подготовка-окружения)
    * [Шаг 2. Клонирование репозитория](#шаг-2-клонирование-репозитория)
    * [Шаг 3. Внешние зависимости](#шаг-3-внешние-зависимости)
    * [Шаг 4. Проверка версии MongoDB](#шаг-4-проверка-версии-mongodb)
    * [Шаг 5. Настройка HTTPS](#шаг-5-настройка-https)
    * [Шаг 6. Обновление конфигурации](#шаг-6-обновление-конфигурации)
    * [Шаг 7. Запуск UnicChat](#шаг-7-запуск-unicchat)
    * [Шаг 8. Обновление настроек MongoDB](#шаг-8-обновление-настроек-mongodb)
    * [Шаг 9. Создание пользователя-администратора](#шаг-9-создание-пользователя-администратора)
    * [Шаг 10. Карта сетевых взаимодействий сервера](#шаг-10-карта-сетевых-взаимодействий-сервера)
    * [Частые проблемы при установке](#частые-проблемы-при-установке)
    * [Клиентские приложения](#клиентские-приложения)
<!-- TOC -->

## Архитектура установки

#### Установка на 1-м сервере
![](./assets/1vm-unicchat-install-scheme.jpg "Архитектура установки на 1-м сервере")

## Шаг 1. Подготовка окружения

#### Требования к конфигурации до 50 пользователей. Приложение и БД устанавливаются на 1-й виртуальной машине

##### Конфигурация виртуальной машины
```
CPU 4 cores 1.7ghz, с набором инструкций FMA3, SSE4.2, AVX 2.0;
RAM 16 Gb;
250 Gb HDD\SSD;
```

## Шаг 2. Клонирование репозитория
1. Выполните на сервере:
   ```shell
   git clone https://github.com/unicommorg/unicchat.git
   ```

## Шаг 3. Внешние зависимости
На виртуальную машину установите `docker`, `docker-compose`, и `nginx`, для этого воспользуйтесь инструкциями для вашей ОС, размещенными в сети Интернет.

## Шаг 4. Проверка версии MongoDB
1. На виртуальной машине выполните команду:
   ```shell
   grep avx /proc/cpuinfo
   ```
   или аналогичную для вашей ОС.
2. Если в ответе вы не видите AVX, то в файле `./single_server_install/unicchat.yml` в строке `image: docker.io/bitnami/mongodb:${MONGODB_VERSION:-4.4}` убедитесь, что указана версия MongoDB 4.4.
3. Если AVX поддерживается (в ответе есть строки с поддержкой AVX), то можете поставить версию от 5 и выше.

## Шаг 5. Настройка HTTPS
1. Установите Certbot для получения SSL-сертификата:
   ```shell
   sudo apt-get update
   sudo apt-get install certbot python3-certbot-nginx
   ```
2. Получите SSL-сертификат для домена `app.unic.chat`:
   ```shell
   sudo certbot --nginx -d app.unic.chat 
   ```
3. Создайте файл конфигурации Nginx для UnicChat, например, `/etc/nginx/sites-available/app.unic.chat`:
   ``` nginx

upstream internal {
    server 127.0.0.1:8080;
}

server {
    listen 443 ssl;
    server_name app.unic.chat;

    client_max_body_size 200M;

    error_log /var/log/nginx/app.unic.chat.error.log;
    access_log /var/log/nginx/app.unic.chat.access.log;

    # CORS-заголовки
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Credentials true;
    add_header "Access-Control-Allow-Methods" "GET, POST, OPTIONS, HEAD";
    add_header "Access-Control-Allow-Headers" "Authorization, Origin, X-Requested-With, Content-Type, Accept";

    # Preflight-запросы
    if ($request_method = OPTIONS) {
        return 204;
    }

    location / {
        proxy_pass http://internal;
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

    ssl_certificate /etc/letsencrypt/live/app.unic.chat/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.unic.chat/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    listen 80;
    server_name app.unic.chat;

    # HTTP перенаправление на HTTPS
    return 301 https://$host$request_uri;
}
 ```
4. Активируйте конфигурацию:
   ```shell
   sudo ln -s /etc/nginx/sites-available/app.unic.chat /etc/nginx/sites-enabled/app.unic.chat
   sudo nginx -t
   sudo systemctl reload nginx
   ```

## Шаг 6. Обновление конфигурации
1. Убедитесь, что файл `./single_server_install/unicchat.yml` содержит следующую конфигурацию:
   ```yaml
   version: "3.5"
   services:
     unic.chat:
       container_name: unic.chat.appserver
       image: cr.yandex/crpvpl7g37r2id3i2qe5/unic_chat_appserver:prod.6-2.1.70
       restart: on-failure
       environment:
         - MONGO_URL=mongodb://ucusername:ucpassword@mongodb:27017/dbuc1?replicaSet=rs0
         - MONGO_OPLOG_URL=mongodb://ucusername:ucpassword@mongodb:27017/local
         - ROOT_URL=http://localhost:8080
         - PORT=8080
         - DEPLOY_METHOD=docker
         - UNIC_SOLID_HOST=http://Internal_IP:8081  # укажите ваш внутренний IP-адрес
         - LIVEKIT_HOST=wss://lk-yc.unic.chat
       volumes:
         - chat_data:/app/uploads
       ports:
         - "8080:8080"
       networks:
         - unic-chat
       depends_on:
         - mongodb

     mongodb:
       image: docker.io/bitnami/mongodb:${MONGODB_VERSION:-4.4}
       container_name: unic.chat.db.mongo
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
         MONGODB_ROOT_PASSWORD: "rootpassword"
         MONGODB_USERNAME: "ucusername"
         MONGODB_PASSWORD: "ucpassword"
         MONGODB_DATABASE: "dbuc1"
       networks:
         - unic-chat
       ports:
         - "27017:27017"

     uc.score:
       image: cr.yandex/crpi5ll6mqcn793fvu9i/unicchat.solid/prod:prod250421
       container_name: uc.score.manager
       restart: on-failure
       env_file: ./app/environment.env
       ports:
         - "8081:8080"
       networks:
         - unic-chat
       depends_on:
         - unic.chat

   networks:
     unic-chat:
       driver: bridge

   volumes:
     mongodb_data:
       driver: local
     chat_data:
       driver: local
   ```
2. Убедитесь, что файл `./single_server_install/app/environment.env` содержит следующую конфигурацию:
   ```
   UnInit.0="'Mongo': { 'Type': 'DbConStringEntry', 'ConnectionString': 'mongodb://ucusername:ucpassword@mongodb:27017/dbuc1?replicaSet=rs0', 'DataBase': 'dbuc1' }"
   InitConfig:Names={Mongo}
   Plugins:Attach={ UniAct Mongo Logger UniVault Tasker db0 Bot Bot.HlpDsk}
   ```
3. Замените `Internal_IP` в `UNIC_SOLID_HOST` на фактический внутренний IP-адрес вашего сервера.

## Шаг 7. Запуск UnicChat
1. Выполните авторизацию в Docker для скачивания образов:
   ```shell
   sudo docker login \
     --username oauth \
     --password y0_AgAAAAB3muX6AATuwQAAAAEawLLRAAB9TQHeGyxGPZXkjVDHF1ZNJcV8UQ \
     cr.yandex
   ```
2. Перейдите в каталог `./single_server_install`:
   ```shell
   cd single_server_install
   ```
3. Запустите сервер, выполнив команду:
   ```shell
   docker compose -f unicchat.yml up -d
   ```
4. Дождитесь загрузки образов компонент, это может занять некоторое время. После загрузки компоненты запустятся автоматически.
5. Успешный запуск компонент будет отображаться в терминале:
   ![](./assets/server-started.png "Пример отображения запуска компонент")
6. После запуска компонент, UnicChat будет доступен по адресу `http://localhost:8080`.

## Шаг 8. Обновление настроек MongoDB
1. Подключитесь к контейнеру MongoDB с использованием root-учетной записи:
   ```shell
   docker exec -it unic.chat.db.mongo mongosh -u root -p rootpassword
   ```
2. Перейдите в базу данных `dbuc1`:
   ```javascript
   use dbuc1
   ```
3. Выполните команды для обновления настроек `Site_Url`:
   ```javascript
   db.rocketchat_settings.updateOne({"_id":"Site_Url"},{"$set":{"value":"https://app.unic.chat"}})
   db.rocketchat_settings.updateOne({"_id":"Site_Url"},{"$set":{"packageValue":"https://app.unic.chat"}})
   ```
4. Выйдите из MongoDB:
   ```shell
   exit
   ```
5. UnicChat будет доступен по адресу `https://app.unic.chat`.
## Шаг 9. Создание пользователя-администратора
1. При первом запуске откроется форма создания администратора:
   ![](./assets/form-setup-wizard.png "Форма создания администратора")
   * `Organization ID` - Идентификатор вашей организации, используется для подключения к push-серверу. Может быть указан позже. Для получения ID необходимо написать запрос с указанием значения в Organization Name на почту support@unic.chat;
   * `Full name` - Имя пользователя, которое будет отображаться в чате;
   * `Username` - Логин пользователя, который вы будете указывать для авторизации;
   * `Email` - Действующая почта, используется для восстановления доступа;
   * `Password` - Пароль вашего пользователя;
   * `Confirm your password` - Подтверждение пароля;
2. После создания пользователя авторизуйтесь в веб-интерфейсе с использованием ранее указанных параметров.
3. Для включения пушей перейдите в раздел Администрирование - Push. Включите использование шлюза и укажите адрес шлюза `https://push1.unic.chat`.
4. Перейдите в раздел Администрирование - Organization, убедитесь, что поля заполнены в соответствии с п.1.
5. Настройка завершена.

## Шаг 10. Карта сетевых взаимодействий сервера

#### Входящие соединения на стороне сервера UnicChat:
Открыть порты:
- 8080/TCP - по умолчанию, сервер запускается на 8080 порту (для внутреннего проксирования через Nginx);
- 8081/TCP - для сервиса `uc.score`;
- 443/TCP - для HTTPS-соединений через Nginx;
- 80/TCP - для перенаправления HTTP-запросов на HTTPS;

#### Исходящие соединения на стороне сервера UnicChat:
* Открыть доступ для Push-шлюза:
  * 443/TCP, на хост `push1.unic.chat`;
* Открыть доступ для ВКС-сервера:
  * 443/TCP, на хост `lk-yc.unic.chat`;
  * 7880/TCP, 7881/TCP, 7882/UDP;
  * 5349/TCP, 3478/UDP;
  * (50000 - 60000)/UDP (диапазон этих портов может быть изменён при развертывании лицензионной версии непосредственно владельцем лицензии);
* Открыть доступ до внутренних ресурсов: LDAP, SMTP, DNS при необходимости использования этого функционала.

## Частые проблемы при установке
Раздел в наполнении.

## Клиентские приложения
* [Репозитории клиентских приложений]
* Android: (https://play.google.com/store/apps/details?id=pro.unicomm.unic.chat&pcampaignid=web_share)
* iOS: (https://apps.apple.com/ru/app/unicchat/id1665533885)
* Desktop: (https://github.com/unicommorg/unic.chat.desktop.releases/releases)
