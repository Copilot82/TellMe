# Changelog

The format is based on Keep a Changelog. Versions follow Semantic Versioning where a change affects
the public wire contract or a reproducible release artifact.

## [Unreleased]

### Added

- a public technical documentation set;
- a reproducible local Compose environment for the Rust backend;
- GitHub Actions workflows for Rust, iOS, and documentation;
- Dependabot, a security policy, and documented GitHub repository controls;
- a production Compose stack, configuration generator, and complete self-hosting runbook;
- unit, UI, and headless E2E test publication without runtime secrets.

### Changed

- the README now serves as the technical entry point for the project;
- the local iOS profile uses Rust backend port `3100`;
- Rust package metadata now matches application version `2.0.0`.

## [2.0.0] — 2026-07-19

### Added

- stable iOS onboarding and account-scoped secure storage;
- device certificates, linking, and revocation flows;
- X3DH/Double Ratchet messaging for individual devices;
- ciphertext mailboxes, realtime synchronization, and a Socket.IO-compatible transport;
- encrypted attachments with capability-based download;
- WebRTC audio/video calls, CallKit, and Picture in Picture;
- an Axum/SQLx Rust backend with PostgreSQL, Redis, and MinIO;
- federation transport with signed server-to-server requests;
- APNs alert/VoIP delivery with privacy-first payloads;
- background workers for outbox, push, and cleanup processing.

### Removed

- legacy plaintext call signaling;
- the pre-federation storage model;
- server-side fields that exposed sender identity in push jobs.

## [0.1.0] — 2026-07-06

- established the first stable backend and iOS shell baseline.

[Unreleased]: https://github.com/Copilot82/TellMe/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/Copilot82/TellMe/releases/tag/v2.0.0
[0.1.0]: https://github.com/Copilot82/TellMe/releases/tag/v0.1.0
