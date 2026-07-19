# Резервное копирование и восстановление

## 1. Состав backup

Для восстановления экземпляра необходимы:

- логический dump PostgreSQL;
- ciphertext objects из MinIO volume;
- `.env.production`;
- APNs `.p8` key либо возможность выпустить новый;
- выбранный Git commit/tag и список image IDs;
- при необходимости Caddy data для сохранения ACME state.

Redis содержит координационное realtime-состояние и в обязательный backup не входит. Локальные
ratchet/private keys находятся на устройствах и серверным backup не восстанавливаются.

Backup содержит routing metadata, account/device records и ciphertext. Храните его как
конфиденциальный: шифруйте до передачи вне VPS, ограничивайте доступ и задавайте retention.

## 2. Подготовить каталог

```bash
cd /opt/tellme/app
BACKUP_ID="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/var/backups/tellme/$BACKUP_ID"
sudo install -d -m 0700 "$BACKUP_DIR"
git rev-parse HEAD | sudo tee "$BACKUP_DIR/git-commit.txt" >/dev/null
sudo docker compose --env-file .env.production -f compose.production.yml images \
  | sudo tee "$BACKUP_DIR/images.txt" >/dev/null
```

Переменные `BACKUP_ID` и `BACKUP_DIR` действуют только в текущем shell. Не используйте пустое или
непроверенное значение в командах удаления.

## 3. Создать согласованный backup

Операция включает короткое окно недоступности записи.

```bash
cd /opt/tellme/app
sudo docker compose --env-file .env.production -f compose.production.yml stop server

sudo docker compose --env-file .env.production -f compose.production.yml exec -T postgres \
  sh -lc 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  | sudo tee "$BACKUP_DIR/postgres.dump" >/dev/null

sudo docker compose --env-file .env.production -f compose.production.yml stop minio
sudo docker run --rm \
  -v tellme_minio_data:/source:ro \
  -v "$BACKUP_DIR":/backup \
  alpine:3.22 \
  tar -C /source -czf /backup/minio-data.tar.gz .

sudo install -m 0600 .env.production "$BACKUP_DIR/env.production"
sudo install -m 0600 secrets/apns/AuthKey.p8 "$BACKUP_DIR/AuthKey.p8"

sudo docker compose --env-file .env.production -f compose.production.yml start minio server
sudo docker compose --env-file .env.production -f compose.production.yml ps
curl --fail https://chat.corp.example/ready
```

Если `APNS_ENABLED=false` и key отсутствует, пропустите команду копирования `AuthKey.p8` и
зафиксируйте это в backup manifest. Замените `chat.corp.example` своим доменом.

Проверьте файлы без вывода содержимого:

```bash
sudo test -s "$BACKUP_DIR/postgres.dump"
sudo test -s "$BACKUP_DIR/minio-data.tar.gz"
sudo sha256sum "$BACKUP_DIR/postgres.dump" "$BACKUP_DIR/minio-data.tar.gz" \
  | sudo tee "$BACKUP_DIR/SHA256SUMS" >/dev/null
sudo ls -lh "$BACKUP_DIR"
```

Шифрование и выгрузка в off-site storage зависят от инфраструктуры организации. Не копируйте
`env.production` или `AuthKey.p8` в нешифрованный object bucket либо GitHub artifact.

## 4. Проверить backup восстановлением

Проверка выполняется в отдельном Compose project и не затрагивает production volumes.

```bash
cd /opt/tellme/app
cp "$BACKUP_DIR/env.production" .env.restore
chmod 600 .env.restore

sed -i \
  -e 's/^SERVER_DOMAIN=.*/SERVER_DOMAIN=localhost/' \
  -e 's/^TURN_EXTERNAL_IP=.*/TURN_EXTERNAL_IP=127.0.0.1/' \
  -e 's/^TURN_PRIVATE_IP=.*/TURN_PRIVATE_IP=127.0.0.1/' \
  -e 's/^HTTP_PORT=.*/HTTP_PORT=28080/' \
  -e 's/^HTTPS_PORT=.*/HTTPS_PORT=28443/' \
  -e 's/^TURN_LISTENING_PORT=.*/TURN_LISTENING_PORT=23478/' \
  -e 's/^TURN_TLS_PORT=.*/TURN_TLS_PORT=25349/' \
  -e 's/^TURN_MIN_PORT=.*/TURN_MIN_PORT=56000/' \
  -e 's/^TURN_MAX_PORT=.*/TURN_MAX_PORT=56050/' \
  -e 's/^APNS_ENABLED=.*/APNS_ENABLED=false/' \
  .env.restore

sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  up -d postgres redis minio
```

Восстановите PostgreSQL в пустую базу restore-проекта:

```bash
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  exec -T postgres sh -lc 'pg_restore --clean --if-exists --no-owner \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <"$BACKUP_DIR/postgres.dump"
```

Восстановите MinIO только в явно названный restore volume:

```bash
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml stop minio
sudo docker run --rm \
  -v tellme-restore_minio_data:/target \
  -v "$BACKUP_DIR":/backup:ro \
  alpine:3.22 \
  sh -lc 'find /target -mindepth 1 -delete && tar -C /target -xzf /backup/minio-data.tar.gz'
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml start minio
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml up -d --build server
```

Проверьте server и данные внутри isolated network:

```bash
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  exec -T server wget -qO- http://127.0.0.1:3100/ready

sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  exec -T postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM schema_migrations;"'
```

Для содержательной проверки сравните counts ключевых таблиц и число media objects с manifest
backup. Не подключайте production-клиенты к restore project.

После фиксации результата удалите только restore project:

```bash
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  down --volumes --remove-orphans --rmi local
rm -f .env.restore
```

Команда `down --volumes` необратимо удаляет volumes `tellme-restore_*`. Перед выполнением проверьте,
что параметр `-p tellme-restore` присутствует и production project не выбран.

## 5. Полное восстановление production

Полное восстановление на новый VPS выполняйте так:

1. установите Docker и checkout исходный commit из manifest;
2. восстановите `.env.production` и APNs key с правами `0600`;
3. создайте volumes запуском только `postgres redis minio`;
4. восстановите PostgreSQL и MinIO по той же процедуре;
5. запустите `server`, дождитесь migrations и проверьте `/ready` внутри container;
6. только после этого запустите `caddy coturn` и переключите DNS;
7. выполните весь [production acceptance](deployment-verification.md).

Не запускайте два worker-enabled backend против одной и той же базы без проверки claim/rollout
модели. DNS TTL уменьшайте заранее, а старый VPS оставляйте неизменным до завершения acceptance.
