# TellMe

[Русский](README.md) | English

TellMe is a source base for a company-operated iOS messenger. The repository contains the iOS
client, Rust backend, PostgreSQL migrations, Redis and S3 integration, TURN configuration, tests,
and deployment documentation. An organization deploys the server on its own domain and VPS and
ships the client under its own Apple Developer account.

The app implements end-to-end encrypted one-to-one messaging, per-device delivery, encrypted
attachments, and WebRTC audio/video calls. The backend routes public key material and ciphertext;
it does not receive the private keys required to decrypt conversations.

> [!IMPORTANT]
> Development and maintenance have ended. Third-party pull requests, issues, integration requests,
> and support requests are not processed. The repository is published as a completed engineering
> reference and as a code base that an organization may maintain independently.

> [!CAUTION]
> The cryptographic protocol has not undergone an independent audit. Do not use it for critical
> data without a separate implementation, infrastructure, and threat-model review.

## TestFlight beta

The public beta link is
[https://testflight.apple.com/join/qP7BxM1e](https://testflight.apple.com/join/qP7BxM1e). The link
may report that the build is unavailable until Apple completes TestFlight App Review.

## Self-hosting prerequisites

- an active Apple Developer Program membership and App Store Connect access;
- a Mac with Xcode 26.2 for the documented build and test path;
- unique App ID, notification-extension ID, App Group ID, and an APNs `.p8` key;
- a controlled domain with A/AAAA records pointing to a VPS;
- a 64-bit Ubuntu 24.04 LTS VPS with a static public IP, Docker Engine, and Compose v2;
- at least 2 vCPU, 4 GB RAM, and 30 GB SSD; 4 vCPU and 8 GB RAM are recommended;
- TCP 80/443/3478 and UDP 3478/49152–65535 available at the host and provider firewall.

The canonical documentation is maintained in Russian:

- [requirements](docs/requirements.md);
- [full corporate deployment](docs/deployment.md);
- [Apple Developer and iOS configuration](docs/apple-setup.md);
- [installation verification](docs/deployment-verification.md);
- [architecture](docs/architecture.md);
- [threat model](docs/threat-model.md);
- [testing strategy](docs/testing.md).

## Local backend

The local path requires Git, Docker Engine/Compose v2, 4 GB of available RAM, 10 GB of disk space,
and free ports 3100, 5432, 6379, 9000, and 9001.

```bash
git clone https://github.com/Copilot82/TellMe.git
cd TellMe
cp .env.example .env
docker compose -f compose.dev.yml up -d --build
docker compose -f compose.dev.yml ps
curl --fail http://localhost:3100/health
curl --fail http://localhost:3100/api/config
```

This development stack intentionally omits public TLS, production APNs, and an Internet-accessible
TURN relay. Follow the [production guide](docs/deployment.md) for an actual company instance.

The source code is distributed under the [MIT License](LICENSE). The license does not include
technical support, a security audit, or a fitness warranty.
