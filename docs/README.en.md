# TellMe technical documentation

These documents describe protocol v2 and the Rust backend as shipped in release `2.0.0`. If the
documentation differs from the implementation, the source code and automated contract tests take
precedence.

## Document map

| Document | Purpose | Primary audience |
| --- | --- | --- |
| [Requirements](requirements.md) | Apple access, devices, domain, VPS, and network | technical lead |
| [Production deployment](deployment.md) | clean VPS to iOS release | implementation engineer |
| [Apple Developer and iOS](apple-setup.md) | identifiers, APNs, signing, and TestFlight | iOS/release engineer |
| [Installation verification](deployment-verification.md) | production acceptance gates | operations engineer |
| [Backup and restore](backup-and-restore.md) | consistent backups and recovery exercises | operations engineer |
| [Troubleshooting](troubleshooting.md) | common TLS, Docker, TURN, and APNs failures | operations engineer |
| [Architecture](architecture.md) | components, trust boundaries, and data flows | developer, architect |
| [Threat model](threat-model.md) | assets, trust assumptions, threats, and limitations | security reviewer |
| [Protocol](protocol.md) | identity, X3DH, ratchet, fan-out, media, and calls | client/backend developer |
| [API](api.md) | HTTP/WebSocket surface and authentication | client developer |
| [Local development](local-development.md) | local startup and configuration | developer |
| [Testing](testing.md) | test layers and release gates | developer, reviewer |
| [Operations](operations.md) | runtime model and observability | operations engineer |
| [Code style](code-style.md) | code and comment conventions | developer |
| [ADR index](adr/README.md) | accepted architectural decisions | architect, reviewer |
| [PiP stabilization](case-studies/pip-stabilization.md) | physical-device diagnostic case study | iOS developer |
| [GitHub configuration](github-settings.md) | Pages, releases, security, and access policy | repository owner |

## Maintenance rules

Documentation changes belong in the same change set as the contract they describe. At minimum:

- a new endpoint updates `api.md` and its contract tests;
- a plaintext/ciphertext boundary change updates `architecture.md` and `threat-model.md`;
- a key-derivation or device-trust change updates `protocol.md` and receives a dedicated ADR;
- a new runtime dependency updates `local-development.md`, `operations.md`, and Compose;
- a new test harness updates `testing.md` and the relevant CI workflow.

Raw credentials, production IP addresses, seed phrases, private keys, and runtime `.env` contents
must never be added to the documentation.
