# Deployment requirements

## 1. Select the target scenario

Determine the intended outcome before installation because each scenario has different
prerequisites.

| Scenario | Result | Apple Developer | Domain and VPS |
| --- | --- | --- | --- |
| Evaluate the beta | install the published TestFlight build | not required | not required |
| Local development | backend on macOS/Linux and client in Simulator | not required for Simulator | not required |
| Run on a personal iPhone | development build signed by your team | a signing team is required; free-account capabilities are limited | backend may run locally |
| Corporate deployment | organization-owned domain, APNs, TURN, and TestFlight distribution | active paid membership is required | required |

Public beta: [TestFlight](https://testflight.apple.com/join/qP7BxM1e). The link may not provide a
build until Apple completes TestFlight App Review.

## 2. Apple access and workstation

An organization-managed distribution path requires:

- active organizational membership in the [Apple Developer Program](https://developer.apple.com/programs/enroll/);
- a role allowed to create identifiers and keys and to manage the app in App Store Connect;
- an Internet-connected Mac with Xcode 26.2;
- an Apple Account added under **Xcode → Settings → Accounts**;
- access to [App Store Connect](https://appstoreconnect.apple.com/);
- a physical iPhone or iPad for APNs, CallKit, camera, microphone, and real TURN validation.

The deployment target is iOS/iPadOS `15.0`, with both iPhone and iPad device families enabled. CI
and the documented commands are verified with Xcode 26.2 and the iOS 26.2 Simulator. Older Xcode
versions are outside the documented `2.0.0` build path even if individual sources compile.

The organization needs three unique identifiers:

| Identifier | Example | Purpose |
| --- | --- | --- |
| App ID | `com.company.tellme` | main target and APNs topic |
| Extension App ID | `com.company.tellme.NotificationService` | Notification Service Extension |
| App Group | `group.com.company.tellme` | shared signing contract for both targets |

The backend requires an APNs authentication key (`.p8`), its Key ID, and the Apple Team ID. Apple
does not allow the private key file to be downloaded again after creation, so treat it as a
production secret. See Apple's instructions for [creating a private key](https://developer.apple.com/help/account/keys/create-a-private-key)
and [token-based APNs connections](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens/).

## 3. Domain and DNS

Use a controlled domain and a dedicated fully qualified service name, for example
`chat.corp.example`. The following conditions are required:

- an A record points to the public IPv4 address of the VPS;
- an AAAA record is present only when IPv6 is actually configured;
- the DNS provider permits record and TTL changes;
- TCP `80` and `443` are reachable from the Internet for TLS issuance and renewal;
- CDN proxy mode is disabled during initial diagnostics;
- the same FQDN is used in `SERVER_DOMAIN`, the iOS API/WebSocket endpoints, and TURN URLs.

The same FQDN may serve HTTPS and TURN. A separate `turn.corp.example` name is also valid, but it
needs its own A/AAAA record and matching `TURN_SERVER_URL_*` values.

## 4. VPS and operating system

The documented deployment is verified on 64-bit Ubuntu 24.04 LTS. Docker also supports Ubuntu
22.04 LTS and the releases listed in the [Docker Engine installation guide](https://docs.docker.com/engine/install/ubuntu/),
but repository commands and smoke tests target 24.04.

The VPS must provide:

- a static public IPv4 address;
- SSH access for a user with `sudo`;
- an x86_64/amd64 or arm64 CPU;
- clock synchronization through systemd-timesyncd or chrony;
- outbound TCP `443` to registries, GitHub, ACME, and APNs;
- the ability to expose a large UDP relay range;
- a filesystem that supports Docker volumes.

### Resource profile

These values are operational estimates, not software limits.

| Workload | CPU | RAM | Disk | Intended use |
| --- | ---: | ---: | ---: | --- |
| Minimum smoke/pilot | 2 vCPU | 4 GB | 30 GB SSD | limited user population |
| Initial corporate deployment | 4 vCPU | 8 GB | 80 GB SSD | operational deployment with build and backup headroom |
| Higher load | 8+ vCPU | 16+ GB | based on retention | requires DB, media, and TURN traffic measurements |

The first Rust Docker build consumes more memory and disk than the running binary. On a 4 GB VPS,
configure swap and avoid concurrent heavy builds. Disk demand is primarily driven by encrypted
attachments, PostgreSQL retention, and backups.

## 5. Network requirements

| Direction | Protocol/port | Source | Purpose |
| --- | --- | --- | --- |
| inbound | TCP `80` | Internet | ACME challenge and HTTPS redirect |
| inbound | TCP `443` | devices | API, WebSocket, and TLS |
| inbound | UDP `3478` | devices | STUN/TURN |
| inbound | TCP `3478` | devices | TURN fallback |
| inbound, optional | TCP `5349` | devices | TURN over TLS with separate coturn TLS configuration |
| inbound | UDP `49152–65535` | devices/peers | TURN relay allocations |
| inbound | TCP `22` | administrative IPs | SSH |
| outbound | TCP `443` | backend | APNs, registries, GitHub, and ACME |

Do not expose PostgreSQL `5432`, Redis `6379`, MinIO `9000/9001`, or backend `3100` publicly.

Docker warns that published container ports can bypass UFW or firewalld rules. Apply restrictions
at the cloud-provider firewall and, when required, in the `DOCKER-USER` chain. See **Firewall
limitations** in the [official Docker instructions](https://docs.docker.com/engine/install/ubuntu/).

If the VPS is behind NAT, set `TURN_EXTERNAL_IP` to its public address and `TURN_PRIVATE_IP` to the
VPS interface address. On a VPS with the public address assigned directly to the interface, both
values are normally identical.

## 6. Local environment

`compose.dev.yml` requires:

- Git;
- Docker Desktop, or Docker Engine with Compose v2;
- 4 GB of available RAM and approximately 10 GB of disk space;
- free TCP ports `3100`, `5432`, `6379`, `9000`, and `9001`.

Override ports with `TELLME_HTTP_PORT`, `TELLME_POSTGRES_PORT`, `TELLME_REDIS_PORT`,
`TELLME_MINIO_PORT`, and `TELLME_MINIO_CONSOLE_PORT`. If the HTTP port changes, update the endpoint
in the iOS local profile as well.

## 7. Components that are not required

TellMe does not require an SMTP server, Kubernetes, an external Redis/PostgreSQL service, or paid
S3 storage. These components may be moved to managed services for a specific deployment, while the
published Compose configuration uses local Docker volumes and MinIO. APNs may be disabled for a
server-only smoke test; it is required for background notifications and incoming calls on physical
devices.
