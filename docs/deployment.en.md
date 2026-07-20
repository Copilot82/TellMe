# Deploying a corporate instance

## 1. Outcome and scope

This guide deploys the following stack on a single VPS:

- Caddy terminates HTTPS and WebSocket traffic and manages TLS automatically;
- the Rust server provides the API, migrations, and background workers;
- PostgreSQL stores accounts, devices, mailboxes, and job metadata;
- Redis coordinates realtime presence;
- MinIO stores encrypted media objects;
- coturn provides the STUN/TURN relay;
- the backend calls APNs for alert and VoIP wakeups.

The commands target a clean Ubuntu 24.04 LTS VPS and a user with `sudo` access. Review the
[complete requirements](requirements.md) before starting. Do not apply this guide over an existing
installation unless a backup and migration plan are in place.

## 2. Prepare the deployment values

Record the following values in a restricted internal document:

```text
SERVER_DOMAIN=chat.corp.example
PUBLIC_IPV4=203.0.113.25
PRIVATE_IPV4=203.0.113.25
APPLE_TEAM_ID=XXXXXXXXXX
APNS_KEY_ID=YYYYYYYYYY
APP_BUNDLE_ID=com.company.tellme
```

The `203.0.113.0/24` network and `example.*` domains used in this documentation are reserved
examples and are not routable.

## 3. Configure DNS

Create an A record with the DNS provider:

```text
chat.corp.example.  A  203.0.113.25
```

Wait for propagation, then verify the record from both the workstation and the VPS:

```bash
dig +short A chat.corp.example
```

The response must contain the VPS public IPv4 address. Do not create an AAAA record until IPv6 is
configured on the host and in the firewall. Caddy can obtain a public certificate only after the
domain resolves to the VPS and TCP ports `80/443` are reachable from the Internet. See the
[automatic HTTPS requirements](https://caddyserver.com/docs/quick-starts/https).

## 4. Prepare the VPS

Check the operating system, architecture, disk space, memory, and system time:

```bash
cat /etc/os-release
uname -m
free -h
df -h /
timedatectl status
```

Install the base packages:

```bash
sudo apt update
sudo apt install -y ca-certificates curl git openssl dnsutils
```

### Install Docker from the official apt repository

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

These commands follow the [official Docker instructions for Ubuntu](https://docs.docker.com/engine/install/ubuntu/).
Membership in the `docker` group grants elevated privileges; using `sudo` for Docker commands is a
safer default for an initial installation.

## 5. Configure the firewall

Allow the following traffic in the VPS provider firewall:

```text
TCP 22                 from administrative IP addresses only
TCP 80,443,3478        from the Internet
UDP 3478,49152-65535   from the Internet
```

Do not open TCP `5349` until coturn is configured with a separate TLS certificate. The published
production Compose file declares this listener but does not mount a certificate and key. By
default, the iOS client uses port `3478` with UDP or TCP transport.

Do not expose ports `3100`, `5432`, `6379`, `9000`, or `9001`. When UFW is in use, account for the
fact that Docker may bypass its rules for published ports. Enforce the restriction in the provider
firewall and the `DOCKER-USER` chain.

## 6. Obtain the source code

Use a release tag or an exact commit instead of a moving branch:

```bash
sudo install -d -m 0750 -o "$USER" -g "$USER" /opt/tellme
git clone https://github.com/Copilot82/TellMe.git /opt/tellme/app
cd /opt/tellme/app
git checkout <published-release-tag>
git status --short
```

Copy the tag name from the repository **Releases** page; do not infer it from memory. If no suitable
release is available, record the selected commit hash in the organization's change record and run
`git checkout <commit>`.

## 7. Create the production configuration

```bash
cd /opt/tellme/app
bash scripts/bootstrap-production-env.sh
ls -l .env.production
```

The script creates the file with mode `0600` and generates independent secrets for PostgreSQL,
Redis, JWT, refresh tokens, MinIO, TURN, and the Ed25519 server signing seed. It does not overwrite
an existing file.

Open `.env.production` and replace at least the following values:

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

If the VPS is behind external NAT, set `TURN_PRIVATE_IP` to the internal interface address:

```bash
ip -4 route get 1.1.1.1
```

The `src` field in the response is normally the required private address. Keep the public address
in `TURN_EXTERNAL_IP`.

## 8. Install the APNs key

Complete the [Apple identifier configuration](apple-setup.md) first. Then copy the one-time
downloaded `.p8` file to the server without adding it to Git:

```bash
cd /opt/tellme/app
install -d -m 0700 secrets/apns
install -m 0600 /secure/source/AuthKey_YYYYYYYYYY.p8 secrets/apns/AuthKey.p8
```

Verify only the presence and permissions of the file. Do not print its contents:

```bash
test -s secrets/apns/AuthKey.p8
stat -c '%a %n' secrets/apns/AuthKey.p8
```

For an initial server-only smoke test, leave `APNS_ENABLED=false` and omit the key. Background
notifications and incoming call wakeups will not work on devices in this mode.

## 9. Run the preflight checks

```bash
cd /opt/tellme/app
sudo env TELLME_PRODUCTION_ENV_PATH="$PWD/.env.production" \
  bash scripts/validate-production-config.sh
sudo docker compose --env-file .env.production -f compose.production.yml config --services
```

The expected services are `postgres`, `redis`, `minio`, `server`, `caddy`, and `coturn`. The
validator rejects example addresses, empty required values, and enabled APNs without a key and
complete configuration.

Check for port conflicts before starting the stack:

```bash
sudo ss -lntup | grep -E ':(80|443|3478|5349)\b' || true
```

If a port is already in use, stop and identify the owning process. Do not change production ports
to work around the conflict: the clients, ACME, and TURN must use a consistent configuration.

## 10. Start the stack

```bash
cd /opt/tellme/app
sudo docker compose --env-file .env.production -f compose.production.yml up -d --build
sudo docker compose --env-file .env.production -f compose.production.yml ps
```

The first Rust build can take several minutes. `postgres`, `redis`, `minio`, `server`, and `coturn`
must reach `healthy`; `caddy` must be `running`. Inspect a bounded log snapshot without follow mode:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --tail=200 server caddy coturn
```

Do not publish complete logs if they contain internal addresses, device tokens, or operational
metadata.

## 11. Verify TLS, API, migrations, and TURN

```bash
curl --fail --show-error https://chat.corp.example/health
curl --fail --show-error https://chat.corp.example/ready
curl --fail --show-error https://chat.corp.example/api/config
```

`/api/config` returns the server domain and protocol capabilities. Verify the TURN URLs separately
with the authenticated allocation test referenced below and with an actual client call.

Check the WebSocket upgrade:

```bash
curl --http1.1 --include --no-buffer --max-time 5 \
  'https://chat.corp.example/socket.io/?EIO=4&transport=websocket' \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
```

The first response line must contain `101 Switching Protocols`.

Inspect the applied migrations:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T postgres \
  sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT filename, applied_at FROM schema_migrations ORDER BY filename;"'
```

Run a STUN check from the coturn container:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T coturn \
  sh -lc 'turnutils_stunclient -p "$TURN_LISTENING_PORT" "$TURN_PRIVATE_IP"'
```

Use the secret-safe command in the [installation verification guide](deployment-verification.md)
for a complete authenticated TURN allocation. After the server-side checks, place a real call
between two physical devices on different networks, such as Wi-Fi and cellular.

## 12. Configure and distribute the iOS client

The backend and client must use the same contract:

```text
API           https://chat.corp.example/api
WebSocket     wss://chat.corp.example/socket.io
TURN UDP      turn:chat.corp.example:3478?transport=udp
TURN TCP      turn:chat.corp.example:3478?transport=tcp
APNs topic    com.company.tellme
VoIP topic    com.company.tellme.voip
```

The [Apple setup guide](apple-setup.md) covers replacing the Team ID, Bundle IDs, App Group,
endpoints, certificate-pinning host, and creating a TestFlight build. Do not distribute a build
that still contains another organization's identifiers or production domain.

## 13. Complete final acceptance

The installation is complete only after every item in the
[installation verification guide](deployment-verification.md) passes: TLS, REST, WebSocket,
migrations, media, TURN over UDP and TCP, APNs alert delivery, VoIP wakeup, a relayed call, and a
backup-and-restore exercise.

## 14. Update and roll back

Before an update, follow the [backup guide](backup-and-restore.md), then record the current commit
and image IDs:

```bash
cd /opt/tellme/app
git rev-parse HEAD
sudo docker compose --env-file .env.production -f compose.production.yml images
```

Then deploy the reviewed version:

```bash
git fetch --tags
git checkout <reviewed-tag-or-commit>
sudo env TELLME_PRODUCTION_ENV_PATH="$PWD/.env.production" \
  bash scripts/validate-production-config.sh
sudo docker compose --env-file .env.production -f compose.production.yml up -d --build
```

To roll back the code, return to the previously recorded commit and rebuild the image. A database
rollback is safe only when the new migrations are backward-compatible; there is no automatic
destructive schema rollback.
