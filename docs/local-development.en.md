# Local development

## 1. Requirements

### Backend

- Rust `1.97.1` installed through rustup;
- Docker Engine and Compose v2;
- `cargo-audit` and `cargo-deny` for the complete validation set.

### iOS

- macOS 26;
- Xcode 26.2 or newer;
- iOS 26.2 Simulator to match CI;
- access to Swift Package Manager dependencies.

A production APNs key, TURN secret, and server signing key are not required for local development.

## 2. Backend in Docker

```bash
cp .env.example .env
docker compose -f compose.dev.yml up --build
```

`compose.dev.yml` starts:

- the Rust server on `localhost:3100`;
- PostgreSQL on `localhost:5432`;
- Redis on `localhost:6379`;
- MinIO API/console on `localhost:9000/9001`.

Verify the environment:

```bash
curl --fail http://localhost:3100/health
curl --fail http://localhost:3100/api/config
docker compose -f compose.dev.yml ps
```

Follow logs for one service:

```bash
docker compose -f compose.dev.yml logs -f server
```

Delete local volumes only when a full reset is intended:

```bash
docker compose -f compose.dev.yml down --volumes
```

## 3. Backend process outside Docker

Infrastructure can remain in Docker while the server runs under Cargo:

```bash
docker compose -f compose.dev.yml up -d postgres redis minio
```

Adapt `.env` values to the published host ports:

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

At startup, the backend applies pending SQL migrations and records their names in
`schema_migrations`. Never reorder published migration files.

## 4. iOS Simulator

Open `messenger/messenger.xcodeproj`, select the `messenger` scheme, and add this Run environment
variable:

```text
MESSENGER_APP_ENV=local
```

The local profile matches `compose.dev.yml`:

```text
API: http://localhost:3100/api
WebSocket: ws://localhost:3100/socket.io
```

To target another environment:

```text
E2E_API_BASE_URL=https://example.invalid/api
E2E_WS_BASE_URL=wss://example.invalid/socket.io
```

`MESSENGER_APP_ENV=local` also disables the production certificate-pin configuration. Never use
the local profile for a release archive.

## 5. Environment variables

| Group | Required values | Purpose |
| --- | --- | --- |
| HTTP | `TELLME_RUST_BIND_ADDR`, `SERVER_DOMAIN` | bind address and public contract |
| Database | `DATABASE_URL` | PostgreSQL and migrations |
| Tokens | `JWT_SECRET`, `JWT_REFRESH_SECRET` | session and refresh signing |
| Realtime | `REDIS_URL` | presence and availability events |
| Media | `MINIO_*` | S3-compatible ciphertext storage |
| Workers | `TELLME_RUST_WORKERS_ENABLED` | outbox, push, and cleanup scheduler |
| Federation | `SERVER_SIGN_*` | signed server transport |
| TURN | `TURN_STATIC_SECRET`, `TURN_SERVER_*` | ephemeral relay credentials |
| APNs | `APNS_*` | alert and VoIP provider configuration |

`.env.example` contains development placeholders only. Keep real values outside Git.

## 6. Typical change cycle

1. Update the contract or test before implementation when behavior changes.
2. Modify the service/repository or iOS boundary.
3. Run targeted tests.
4. Run the complete lint and test set for the affected platform.
5. Update API, protocol, or ADR documentation.
6. Run `git diff --check` and verify that no secrets are present.

Production deployment is outside the local quickstart. Follow the [deployment guide](deployment.md)
for the full procedure and [operations](operations.md) for the runtime model.
