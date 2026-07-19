# Развёртывание корпоративного экземпляра

## 1. Результат и границы инструкции

Инструкция поднимает на одном VPS следующий контур:

- Caddy принимает HTTPS и WebSocket traffic и автоматически управляет TLS;
- Rust server выполняет API, migrations и background workers;
- PostgreSQL хранит accounts, devices, mailbox и job metadata;
- Redis координирует realtime presence;
- MinIO хранит зашифрованные media objects;
- coturn предоставляет STUN/TURN relay;
- APNs вызывается backend для alert/VoIP wakeup.

Команды рассчитаны на чистый Ubuntu 24.04 LTS VPS и пользователя с `sudo`. До начала проверьте
[полный список требований](requirements.md). Не выполняйте инструкцию поверх существующей
установки, если не подготовлены backup и план миграции.

## 2. Подготовить значения

Заранее запишите в закрытом рабочем документе:

```text
SERVER_DOMAIN=chat.corp.example
PUBLIC_IPV4=203.0.113.25
PRIVATE_IPV4=203.0.113.25
APPLE_TEAM_ID=XXXXXXXXXX
APNS_KEY_ID=YYYYYYYYYY
APP_BUNDLE_ID=com.company.tellme
```

Значения `203.0.113.0/24` и `example.*` в документации являются примерами и не маршрутизируются.

## 3. Настроить DNS

У DNS-провайдера создайте A-запись:

```text
chat.corp.example.  A  203.0.113.25
```

Дождитесь обновления и проверьте с рабочей станции и с VPS:

```bash
dig +short A chat.corp.example
```

Ответ должен содержать публичный IPv4 VPS. Не создавайте AAAA-запись, пока IPv6 не настроен на
хосте и в firewall. Caddy получает публичный сертификат только когда домен разрешается в VPS и
TCP-порты `80/443` доступны извне. Это соответствует
[требованиям automatic HTTPS](https://caddyserver.com/docs/quick-starts/https).

## 4. Подготовить VPS

Проверьте операционную систему, архитектуру, диск, память и время:

```bash
cat /etc/os-release
uname -m
free -h
df -h /
timedatectl status
```

Установите базовые пакеты:

```bash
sudo apt update
sudo apt install -y ca-certificates curl git openssl dnsutils
```

### Установить Docker из официального apt repository

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
sudo docker compose version
```

Команды следуют [официальной инструкции Docker для Ubuntu](https://docs.docker.com/engine/install/ubuntu/).
Добавление пользователя в группу `docker` эквивалентно выдаче высоких привилегий; для первой
установки безопаснее выполнять Docker-команды через `sudo`.

## 5. Настроить firewall

В firewall VPS-провайдера разрешите:

```text
TCP 22                 только с административных IP
TCP 80,443,3478        из интернета
UDP 3478,49152-65535   из интернета
```

TCP `5349` не открывайте, пока coturn не настроен с отдельным TLS certificate. Опубликованный
production Compose объявляет этот listener, но не монтирует certificate/key и iOS по умолчанию
использует `3478` с UDP/TCP transport.

Не открывайте `3100`, `5432`, `6379`, `9000`, `9001`. При использовании UFW учтите, что Docker
может обходить его правила для published ports; контролируйте доступ на уровне провайдера и
`DOCKER-USER`.

## 6. Получить исходный код

Используйте release tag или конкретный commit, а не плавающую ветку:

```bash
sudo install -d -m 0750 -o "$USER" -g "$USER" /opt/tellme
git clone https://github.com/Copilot82/TellMe.git /opt/tellme/app
cd /opt/tellme/app
git checkout <опубликованный-release-tag>
git status --short
```

Имя tag берите на странице **Releases** репозитория, не подставляйте номер версии по памяти. Если
release ещё не опубликован, зафиксируйте выбранный commit hash в change record организации и
выполните `git checkout <commit>`.

## 7. Создать production-конфигурацию

```bash
cd /opt/tellme/app
bash scripts/bootstrap-production-env.sh
ls -l .env.production
```

Скрипт создаёт файл с mode `0600` и генерирует независимые значения для PostgreSQL, Redis, JWT,
refresh token, MinIO, TURN и Ed25519 server signing seed. Существующий файл не перезаписывается.

Откройте `.env.production` и обязательно измените:

```dotenv
SERVER_DOMAIN=chat.corp.example
TURN_EXTERNAL_IP=203.0.113.25
TURN_PRIVATE_IP=203.0.113.25
STUN_SERVER=stun:chat.corp.example:3478
TURN_SERVER_URL_UDP=turn:chat.corp.example:3478?transport=udp
TURN_SERVER_URL_TCP=turn:chat.corp.example:3478?transport=tcp
APNS_BUNDLE_ID=com.company.tellme
APNS_VOIP_TOPIC=com.company.tellme.voip
APNS_KEY_ID=YYYYYYYYYY
APNS_TEAM_ID=XXXXXXXXXX
APNS_ENABLED=true
APNS_PRODUCTION=true
```

Если у VPS внешний NAT, укажите внутренний address интерфейса в `TURN_PRIVATE_IP`:

```bash
ip -4 route get 1.1.1.1
```

Поле `src` в ответе обычно является требуемым private address. Публичный address остаётся в
`TURN_EXTERNAL_IP`.

## 8. Установить APNs key

Сначала выполните [настройку Apple identifiers](apple-setup.md). Затем скопируйте единственный
скачанный `.p8` на сервер, не добавляя его в Git:

```bash
cd /opt/tellme/app
install -d -m 0700 secrets/apns
install -m 0600 /secure/source/AuthKey_YYYYYYYYYY.p8 secrets/apns/AuthKey.p8
```

Проверяйте только наличие и права, не выводите содержимое:

```bash
test -s secrets/apns/AuthKey.p8
stat -c '%a %n' secrets/apns/AuthKey.p8
```

Для первоначального server-only smoke можно оставить `APNS_ENABLED=false` и не устанавливать key.
Фоновые уведомления и входящие вызовы на устройствах в таком режиме не работают.

## 9. Провести preflight

```bash
cd /opt/tellme/app
sudo env TELLME_PRODUCTION_ENV_PATH="$PWD/.env.production" \
  bash scripts/validate-production-config.sh
sudo docker compose --env-file .env.production -f compose.production.yml config --services
```

Ожидаются сервисы `postgres`, `redis`, `minio`, `server`, `caddy`, `coturn`. Validator отклоняет
template addresses, пустые обязательные значения и включённый APNs без key/config.

Проверьте занятость портов до запуска:

```bash
sudo ss -lntup | grep -E ':(80|443|3478|5349)\b' || true
```

Если порты уже заняты, остановитесь и выясните владельца процесса. Не меняйте production ports для
обхода конфликта: клиенты, ACME и TURN должны использовать согласованную конфигурацию.

## 10. Запустить стек

```bash
cd /opt/tellme/app
sudo docker compose --env-file .env.production -f compose.production.yml up -d --build
sudo docker compose --env-file .env.production -f compose.production.yml ps
```

Первая Rust-сборка может занять несколько минут. `postgres`, `redis`, `minio`, `server` и `coturn`
должны перейти в `healthy`; `caddy` — в `running`. Просмотр логов без follow:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --tail=200 server caddy coturn
```

Не публикуйте полный лог, если он содержит внутренние addresses, device tokens или operational
metadata.

## 11. Проверить TLS, API, migrations и TURN

```bash
curl --fail --show-error https://chat.corp.example/health
curl --fail --show-error https://chat.corp.example/ready
curl --fail --show-error https://chat.corp.example/api/config
```

`/api/config` возвращает server domain и protocol capabilities. TURN URLs подтверждаются отдельным
authenticated allocation test ниже и фактическим клиентским звонком.

Проверка WebSocket upgrade:

```bash
curl --http1.1 --include --no-buffer --max-time 5 \
  'https://chat.corp.example/socket.io/?EIO=4&transport=websocket' \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
```

Начальная строка ответа должна содержать `101 Switching Protocols`.

Проверка применённых migrations:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T postgres \
  sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT filename, applied_at FROM schema_migrations ORDER BY filename;"'
```

Проверка STUN из coturn container:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T coturn \
  sh -lc 'turnutils_stunclient -p "$TURN_LISTENING_PORT" "$TURN_PRIVATE_IP"'
```

Полная authenticated TURN allocation выполняется по безопасной команде из
[проверки установки](deployment-verification.md). После server-side проверок обязательно выполните
реальный звонок между двумя физическими устройствами в разных сетях, например Wi-Fi и cellular.

## 12. Настроить и выпустить iOS-клиент

Backend и клиент должны использовать один contract:

```text
API           https://chat.corp.example/api
WebSocket     wss://chat.corp.example/socket.io
TURN UDP      turn:chat.corp.example:3478?transport=udp
TURN TCP      turn:chat.corp.example:3478?transport=tcp
APNs topic    com.company.tellme
VoIP topic    com.company.tellme.voip
```

Пошаговая замена Team ID, Bundle IDs, App Group, endpoints, certificate pin host и создание
TestFlight build описаны в [apple-setup.md](apple-setup.md). Не распространяйте исходную сборку с
чужими identifiers или production domain.

## 13. Финальный acceptance

Установка считается завершённой только после прохождения всех пунктов
[deployment-verification.md](deployment-verification.md): TLS, REST, WebSocket, migrations, media,
TURN UDP/TCP, APNs alert, VoIP wakeup, звонок через relay, backup и restore exercise.

## 14. Обновление и откат

Перед обновлением выполните процедуру из [руководства backup](backup-and-restore.md), затем
запишите текущий commit и image IDs:

```bash
cd /opt/tellme/app
git rev-parse HEAD
sudo docker compose --env-file .env.production -f compose.production.yml images
```

После этого:

```bash
git fetch --tags
git checkout <проверенный-tag-или-commit>
sudo env TELLME_PRODUCTION_ENV_PATH="$PWD/.env.production" \
  bash scripts/validate-production-config.sh
sudo docker compose --env-file .env.production -f compose.production.yml up -d --build
```

Для отката кода вернитесь на ранее записанный commit и пересоберите image. Откат базы безопасен
только если новые migrations backward-compatible; автоматического destructive rollback схемы нет.
