# Backup and restore

## 1. Backup contents

Restoring an instance requires:

- a logical PostgreSQL dump;
- ciphertext objects from the MinIO volume;
- `.env.production`;
- the APNs `.p8` key, or the ability to issue a replacement;
- the selected Git commit or tag and a list of image IDs;
- optionally, Caddy data to preserve ACME state.

Redis contains realtime coordination state and is not part of the mandatory backup. Local ratchet
state and private keys remain on devices and cannot be restored from a server backup.

A backup contains routing metadata, account and device records, and ciphertext. Treat it as
confidential: encrypt it before transfer from the VPS, restrict access, and define retention.

## 2. Prepare a directory

```bash
cd /opt/tellme/app
BACKUP_ID="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/var/backups/tellme/$BACKUP_ID"
sudo install -d -m 0700 "$BACKUP_DIR"
git rev-parse HEAD | sudo tee "$BACKUP_DIR/git-commit.txt" >/dev/null
sudo docker compose --env-file .env.production -f compose.production.yml images \
  | sudo tee "$BACKUP_DIR/images.txt" >/dev/null
```

`BACKUP_ID` and `BACKUP_DIR` exist only in the current shell. Never use an empty or unverified value
in a deletion command.

## 3. Create a consistent backup

This procedure includes a short write-unavailability window.

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

If `APNS_ENABLED=false` and no key exists, omit the `AuthKey.p8` copy and record that fact in the
backup manifest. Replace `chat.corp.example` with the deployment domain.

Validate files without printing their contents:

```bash
sudo test -s "$BACKUP_DIR/postgres.dump"
sudo test -s "$BACKUP_DIR/minio-data.tar.gz"
sudo sha256sum "$BACKUP_DIR/postgres.dump" "$BACKUP_DIR/minio-data.tar.gz" \
  | sudo tee "$BACKUP_DIR/SHA256SUMS" >/dev/null
sudo ls -lh "$BACKUP_DIR"
```

Encryption and off-site transfer depend on organizational infrastructure. Never upload
`env.production` or `AuthKey.p8` to an unencrypted object bucket or GitHub artifact.

## 4. Verify the backup through restoration

The test uses an isolated Compose project and does not access production volumes.

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

Restore PostgreSQL into the empty restore-project database:

```bash
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  exec -T postgres sh -lc 'pg_restore --clean --if-exists --no-owner \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <"$BACKUP_DIR/postgres.dump"
```

Restore MinIO only into the explicitly named restore volume:

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

Validate the server and data inside the isolated network:

```bash
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  exec -T server wget -qO- http://127.0.0.1:3100/ready

sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  exec -T postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM schema_migrations;"'
```

For semantic validation, compare key-table counts and the number of media objects with the backup
manifest. Never connect production clients to the restore project.

After recording the result, delete only the restore project:

```bash
sudo docker compose --env-file .env.restore -p tellme-restore -f compose.production.yml \
  down --volumes --remove-orphans --rmi local
rm -f .env.restore
```

`down --volumes` irreversibly deletes `tellme-restore_*` volumes. Before running it, verify that
`-p tellme-restore` is present and that the production project is not selected.

## 5. Full production restoration

To restore on a new VPS:

1. install Docker and check out the source commit from the manifest;
2. restore `.env.production` and the APNs key with mode `0600`;
3. create volumes by starting only `postgres redis minio`;
4. restore PostgreSQL and MinIO with the same procedure;
5. start `server`, wait for migrations, and check `/ready` from inside the container;
6. start `caddy coturn` and switch DNS only after the previous checks pass;
7. execute the complete [production acceptance procedure](deployment-verification.md).

Do not run two worker-enabled backend instances against the same database without validating the
claim and rollout model. Lower DNS TTL in advance and keep the old VPS unchanged until acceptance
is complete.
