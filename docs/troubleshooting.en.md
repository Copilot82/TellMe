# Installation troubleshooting

## 1. Collect minimum context

Start with commands that do not expose environment values:

```bash
cd /opt/tellme/app
git rev-parse HEAD
sudo docker version
sudo docker compose version
sudo docker compose --env-file .env.production -f compose.production.yml ps
sudo docker compose --env-file .env.production -f compose.production.yml images
sudo ss -lntup | grep -E ':(80|443|3100|3478|5349)\b' || true
```

Limit logs by service and time window:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --since=15m --tail=300 server
```

Never publish `.env.production`, the APNs key, a `docker inspect` environment, device tokens, seed
phrases, or complete production logs.

## 2. Compose validation fails

| Symptom | Cause | Action |
| --- | --- | --- |
| `template values` | `example.com`, `203.0.113.10`, or `CHANGE_ME` remains | complete `.env.production` |
| `Required variable is empty` | a mandatory contract value is missing | compare with `.env.production.example` |
| APNs key unavailable | `APNS_ENABLED=true`, but the key is not mounted | install `secrets/apns/AuthKey.p8` with mode `0600` |
| port is already allocated | another process or container owns the listener | identify it with `ss` and `docker ps`; do not change ports blindly |

After correction, always repeat:

```bash
sudo env TELLME_PRODUCTION_ENV_PATH="$PWD/.env.production" \
  bash scripts/validate-production-config.sh
```

## 3. Server does not become healthy

```bash
sudo docker compose --env-file .env.production -f compose.production.yml ps server postgres redis minio
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --tail=300 server postgres redis minio
```

Common causes:

- PostgreSQL is not ready or the password differs from the initialized volume;
- `.env.production` changed after PostgreSQL initialization;
- MinIO credentials changed without migrating the existing volume;
- `SERVER_SIGN_PRIVATE_KEY` is not base64 encoding of a 32-byte seed;
- APNs is enabled with incomplete configuration;
- the VPS exhausted RAM or disk during build or migration.

Changing `POSTGRES_PASSWORD` in the environment does not change the password inside an existing
database volume. Restore the previous value or perform a controlled PostgreSQL rotation. Never
delete a production volume as a troubleshooting shortcut.

## 4. Caddy cannot obtain a certificate

```bash
dig +short A chat.corp.example
curl -I http://chat.corp.example
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --tail=300 caddy
```

Verify that:

- DNS points to this VPS;
- provider firewall allows TCP `80/443`, and no other proxy owns the ports;
- an AAAA record does not point to unconfigured IPv6;
- CDN proxy mode is temporarily disabled;
- repeated attempts have not exhausted the ACME rate limit.

Caddy data lives in the `tellme_caddy_data` volume. Deleting it triggers new certificate issuance
and is not a routine troubleshooting step.

## 5. WebSocket does not return 101

REST may work while WebSocket routing is incorrect. Run the command from
[installation verification](deployment-verification.md). Check the exact `/socket.io/` path, the
`EIO=4&transport=websocket` query, and HTTP/1.1 upgrade headers.

A CDN or load balancer in front of Caddy must forward `Upgrade` and `Connection` and must not close
long-lived connections. Connect directly to the VPS during initial validation.

## 6. TURN allocation fails

```bash
sudo docker compose --env-file .env.production -f compose.production.yml ps coturn
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --since=15m coturn
sudo ss -lnup | grep ':3478\b' || true
```

| Message or symptom | Check |
| --- | --- |
| `no available ports` | confirm that the entire `TURN_MIN_PORT–TURN_MAX_PORT` range is open and free and allocations are not exhausted |
| allocation works internally but not externally | provider firewall, NAT mapping, and public/private IP pair |
| `401 Unauthorized` | backend and coturn use different `TURN_STATIC_SECRET` values, or the credential expired |
| `438 Stale Nonce` | clock drift or an excessively delayed client retry |
| calls work only on one network | relay UDP range or TCP fallback is unavailable |

Check clock synchronization with `timedatectl status`. After rotating the TURN secret, recreate
`server` and `coturn` together; otherwise, the backend issues credentials rejected by the relay.

## 7. APNs returns an error

| APNs reason | Likely cause |
| --- | --- |
| `InvalidProviderToken` | incorrect `.p8`, Key ID, Team ID, or signature |
| `ExpiredProviderToken` | incorrect VPS clock or an old provider JWT |
| `BadDeviceToken` | token belongs to another APNs environment |
| `DeviceTokenNotForTopic` | `APNS_BUNDLE_ID` differs from the signed application |
| `Unregistered` | application was removed or the token is no longer active |

Compare Release build settings with `.env.production` without printing the token or key. See
Apple's [APNs response reference](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)
for canonical status and reason values.

## 8. iOS connects to an old domain

A Production Archive does not use scheme environment variables. Inspect embedded build settings:

```bash
xcodebuild -project messenger/messenger.xcodeproj -scheme messenger \
  -configuration Release -showBuildSettings \
  | grep -E 'PRODUCT_BUNDLE_IDENTIFIER|TELLME_(API|WS|TURN|STUN|APP_)'
```

Clear DerivedData only after verifying the settings, then create a new Archive. The build number
must differ from every build already uploaded to App Store Connect.

## 9. Certificate pin blocks networking

If system TLS succeeds through `curl` but the application receives a trust or cancellation error,
compare the leaf certificate SHA-256 value with `TELLME_API_PRIMARY_CERT_SHA256` and the backup pin.
Before a planned renewal, the client must already include a pin for the next certificate.

Never disable TLS verification. If there is no formal pin-rotation process, release a new build
with empty pin settings and rely on the system trust store.

## 10. Safe shutdown

```bash
sudo docker compose --env-file .env.production -f compose.production.yml stop server caddy coturn
```

This command preserves database and object volumes. `down --volumes`, `docker volume rm`, and
manual deletion of `/var/lib/docker` are irreversible and are not routine diagnostic actions.
