# История изменений

Формат основан на Keep a Changelog. Версии следуют Semantic Versioning там, где изменение
затрагивает публичный wire contract или воспроизводимый release artifact.

## [Unreleased]

### Добавлено

- публичный контур технической документации;
- воспроизводимый локальный Compose для Rust backend;
- GitHub Actions для Rust, iOS и документации;
- Dependabot, security policy и read-only GitHub publication policy;
- production Compose, генератор конфигурации и полный self-hosting runbook;
- публикация unit-, UI- и headless E2E-тестов без runtime secrets.

### Изменено

- README преобразован в техническую входную точку проекта;
- локальный iOS profile синхронизирован с портом Rust backend `3100`;
- metadata Rust package приведена к версии приложения `2.0.0`.

## [2.0.0] — 2026-07-19

### Добавлено

- стабильный iOS onboarding и account-scoped secure storage;
- device certificates, linking и revoke flow;
- X3DH/Double Ratchet messaging для отдельных устройств;
- ciphertext mailbox, realtime sync и Socket.IO-compatible transport;
- зашифрованные вложения с capability-based download;
- WebRTC audio/video calls, CallKit и Picture in Picture;
- Rust backend на Axum/SQLx с PostgreSQL, Redis и MinIO;
- federation transport с подписанными server-to-server запросами;
- APNs alert/VoIP delivery с privacy-first payload;
- background workers для outbox, push и cleanup.

### Удалено

- legacy plaintext call signaling;
- pre-federation storage model;
- серверные поля, раскрывавшие sender identity в push jobs.

## [0.1.0] — 2026-07-06

- зафиксирована первая стабильная baseline-версия backend и iOS shell.

[Unreleased]: https://github.com/Copilot82/TellMe/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/Copilot82/TellMe/releases/tag/v2.0.0
[0.1.0]: https://github.com/Copilot82/TellMe/releases/tag/v0.1.0
