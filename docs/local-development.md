# Локальная разработка

## 1. Требования

### Backend

- Rust `1.97.1` через rustup;
- Docker Engine и Compose v2;
- `cargo-audit` и `cargo-deny` для полного набора проверок.

### iOS

- macOS 26;
- Xcode 26.2 или новее;
- iOS 26.2 Simulator для совпадения с CI;
- доступ к Swift Package Manager dependencies.

Production APNs certificate, TURN secret и server signing key для локальной разработки не нужны.

## 2. Backend в Docker

```bash
cp .env.example .env
docker compose -f compose.dev.yml up --build
```

`compose.dev.yml` запускает:

- Rust server на `localhost:3100`;
- PostgreSQL на `localhost:5432`;
- Redis на `localhost:6379`;
- MinIO API/console на `localhost:9000/9001`.

Проверка:

```bash
curl --fail http://localhost:3100/health
curl --fail http://localhost:3100/api/config
docker compose -f compose.dev.yml ps
```

Логи конкретного сервиса:

```bash
docker compose -f compose.dev.yml logs -f server
```

Полный сброс локальных volumes выполняется только осознанно:

```bash
docker compose -f compose.dev.yml down --volumes
```

## 3. Backend без контейнера приложения

Infrastructure можно оставить в Docker, а сервер запускать через Cargo:

```bash
docker compose -f compose.dev.yml up -d postgres redis minio
```

В этом режиме переменные из `.env` нужно адаптировать к host ports:

```bash
cd backend-rust
DATABASE_URL=postgresql://tellme:tellme-dev-password@localhost:5432/tellme \
REDIS_URL=redis://localhost:6379 \
MINIO_ENDPOINT=localhost \
MINIO_PORT=9000 \
MINIO_ACCESS_KEY=tellme-local \
MINIO_SECRET_KEY=tellme-local-password \
JWT_SECRET=local-session-secret-change-before-deploy \
JWT_REFRESH_SECRET=local-refresh-secret-change-before-deploy \
SERVER_DOMAIN=localhost \
TELLME_RUST_BIND_ADDR=127.0.0.1:3100 \
cargo run --locked --bin tellme-server
```

При старте backend применяет pending SQL migrations и записывает их имена в
`schema_migrations`. Порядок migration files менять нельзя после публикации релиза.

## 4. iOS Simulator

Откройте `messenger/messenger.xcodeproj`, выберите scheme `messenger` и добавьте в Run environment:

```text
MESSENGER_APP_ENV=local
```

Local profile соответствует `compose.dev.yml`:

```text
API: http://localhost:3100/api
WebSocket: ws://localhost:3100/socket.io
```

Для другого стенда:

```text
E2E_API_BASE_URL=https://example.invalid/api
E2E_WS_BASE_URL=wss://example.invalid/socket.io
```

`MESSENGER_APP_ENV=local` также отключает production certificate pin configuration. Не используйте
local profile для release archive.

## 5. Переменные окружения

| Группа | Обязательные значения | Назначение |
| --- | --- | --- |
| HTTP | `TELLME_RUST_BIND_ADDR`, `SERVER_DOMAIN` | bind и public contract |
| Database | `DATABASE_URL` | PostgreSQL и migrations |
| Tokens | `JWT_SECRET`, `JWT_REFRESH_SECRET` | session/refresh signing |
| Realtime | `REDIS_URL` | presence и availability events |
| Media | `MINIO_*` | S3-compatible ciphertext storage |
| Workers | `TELLME_RUST_WORKERS_ENABLED` | outbox/push/cleanup scheduler |
| Federation | `SERVER_SIGN_*` | signed server transport |
| TURN | `TURN_STATIC_SECRET`, `TURN_SERVER_*` | ephemeral relay credentials |
| APNs | `APNS_*` | alert/VoIP provider |

`.env.example` содержит только development placeholders. Реальные значения хранятся вне Git.

## 6. Типичный цикл изменения

1. Обновить contract/test до реализации, если меняется поведение.
2. Изменить service/repository или iOS boundary.
3. Выполнить targeted tests.
4. Выполнить полный lint/test набор затронутой платформы.
5. Обновить API/protocol/ADR документацию.
6. Проверить `git diff --check` и отсутствие secrets.

Production deployment не является частью локального quickstart. Полная последовательность
приведена в [руководстве развёртывания](deployment.md), а runtime model — в
[operations.md](operations.md).
