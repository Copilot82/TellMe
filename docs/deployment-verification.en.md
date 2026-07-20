# Production installation verification

## 1. Acceptance rule

Run this procedure after first startup, an image update, or any DNS, TLS, APNs, or TURN change.
`/health` alone is insufficient: it does not prove WebSocket upgrade, migrations, object storage,
APNs, or relay traffic.

Record the date, commit hash, image IDs, and result of every section in the internal change record.
Do not include secrets, device tokens, seed phrases, or complete ciphertext.

## 2. Containers

```bash
cd /opt/tellme/app
sudo docker compose --env-file .env.production -f compose.production.yml ps
sudo docker compose --env-file .env.production -f compose.production.yml images
```

Acceptance criteria:

- `postgres`, `redis`, `minio`, `server`, and `coturn` are `healthy`;
- `caddy` is `running`;
- there are no restart loops or unexpectedly published database or storage ports.

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

## 3. DNS and TLS

```bash
dig +short A chat.corp.example
curl --fail --show-error --verbose https://chat.corp.example/health
openssl s_client -servername chat.corp.example -connect chat.corp.example:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256
```

DNS must contain the VPS address, the certificate chain must be trusted by the system, SAN must
include the domain, `notAfter` must be in the future, HTTP status must be `200`, and the body must
contain `"status":"ok"`.

## 4. API and WebSocket

```bash
curl --fail --show-error https://chat.corp.example/ready
curl --fail --show-error https://chat.corp.example/api/config
```

`/api/config` must return the production domain, wire and protocol versions, and
`"call_signaling":"e2e_message_payload"`. TURN URLs are verified through the authenticated
credentials route in a client scenario and the direct allocation test in section 7; public config
does not expose them.

```bash
curl --http1.1 --include --no-buffer --max-time 5 \
  'https://chat.corp.example/socket.io/?EIO=4&transport=websocket' \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
```

The expected result is `101 Switching Protocols`. A `curl` timeout after a successful upgrade is
not a failure of this check.

## 5. Database migrations

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T postgres \
  sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM schema_migrations;"'
```

Version `2.0.0` expects at least 16 applied migrations. Also confirm that the `server` log contains
no migration error or repeating startup failure.

## 6. MinIO

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T minio \
  curl --fail http://127.0.0.1:9000/minio/health/ready
```

Then send a test attachment from iOS, download it on the second device, and confirm that:

- the server stored the object;
- the recipient decrypted the file;
- a direct unauthenticated request to MinIO is impossible from outside;
- plaintext filename or content did not appear in container logs.

## 7. TURN over UDP and TCP

Do not print `TURN_STATIC_SECRET`. Pass it only inside the container shell:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T coturn \
  sh -lc '
    turnutils_uclient -c -I -Y alloc -n 1 -m 1 \
      -u healthcheck -W "$TURN_STATIC_SECRET" \
      -p "$TURN_LISTENING_PORT" "$TURN_EXTERNAL_IP" >/dev/null &&
    turnutils_uclient -t -c -I -Y alloc -n 1 -m 1 \
      -u healthcheck -W "$TURN_STATIC_SECRET" \
      -p "$TURN_LISTENING_PORT" "$TURN_EXTERNAL_IP" >/dev/null
  '
```

Exit status `0` proves authenticated allocation over UDP and TCP with the current shared secret.
It does not replace an external check: place a video call between physical devices on different
networks and confirm that relay candidates are used when a direct path is unavailable.

```bash
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --since=10m coturn
```

`no available ports` indicates relay-range exhaustion or filtering. Repeated `401/438` errors in a
long session require clock and credential-TTL checks.

## 8. APNs

Validate a Debug development token and a TestFlight production token separately.

1. Launch the app and grant notification permission.
2. Confirm that the device registers alert and VoIP tokens.
3. Move the app to the background and send a message from the second device.
4. Lock the screen and initiate a call.
5. Confirm a generic notification without plaintext and the appearance of CallKit UI.
6. Inspect the bounded server-worker log for the corresponding interval.

There must be no `InvalidProviderToken`, `DeviceTokenNotForTopic`, or `BadDeviceToken`; the push job
must not retry indefinitely; the notification must not disclose message text or caller identity.

## 9. Client end-to-end scenario

On two physical devices:

1. create different test accounts;
2. exchange text messages;
3. take the recipient offline, send a message, and verify mailbox sync after reconnection;
4. send an image and a file;
5. perform an audio call, video call, and Picture in Picture transition;
6. repeat a call across different networks;
7. revoke an additional device and confirm that subsequent fan-out excludes it.

Do not use personal or business data in the acceptance scenario.

## 10. Backup and restore

Create a backup and restore it in a separate temporary Compose project by following
[backup and restore](backup-and-restore.md). A backup that has never been restored is not verified.

## 11. Acceptance record

| Gate | Required result |
| --- | --- |
| Containers | all runtime services remain stable |
| TLS | valid chain and correct hostname |
| REST/ready | HTTP 200 with expected JSON |
| WebSocket | HTTP 101 |
| Migrations | complete ordered set |
| Media | upload, download, and client decryption |
| TURN | authenticated UDP and TCP allocation |
| APNs | alert and VoIP delivery |
| E2E | message, offline sync, media, call, and revocation |
| Recovery | successful isolated restoration |

Production acceptance is complete only when every gate has evidence or a formally accepted
exception with a risk owner and remediation deadline.
