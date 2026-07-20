# Стратегия тестирования

## 1. Цель

Тесты должны доказывать не только happy path, но и сохранение privacy/security invariants. Для
каждого изменения выбирается минимальный быстрый набор, затем release gate соответствующей
платформы.

## 2. Матрица

| Уровень | Инструмент | Что проверяется | Запуск |
| --- | --- | --- | --- |
| Rust unit | `cargo test` | parsing, validation, services, SQL builders, protocol contract | каждое изменение |
| Rust lint | rustfmt/Clippy | стиль, запрещённые конструкции, public API | каждое изменение |
| Dependency | audit/deny | advisories, licenses, sources | каждое изменение/Dependabot |
| iOS unit | XCTest | services, crypto state, view models, networking | каждое изменение |
| iOS UI smoke | XCUITest | ключевые экраны и accessibility contract | main/release |
| Headless E2E | Swift Package | account/device/message flows без UI | каждое изменение |
| Physical E2E | XCUITest + scripts | APNs, CallKit, camera, PiP, background | release candidate |
| Operational smoke | container/health | migrations, startup, rollback boundary | release |
| Public install smoke | Docker Compose | чистая установка по опубликованной конфигурации, TLS, TURN TCP/UDP | изменение deployment contract |

## 3. Rust tests

Backend unit tests находятся рядом с implementation modules. Такой layout позволяет проверять
private validation helpers без расширения production API.

Основные категории:

- auth challenge, signature и token rotation;
- device certificate, linking и revoke;
- one-time prekey consumption;
- ciphertext-only message/mailbox SQL;
- media capability, attestation и object signing;
- federation canonical signature;
- Socket.IO codec и запрет plaintext call events;
- worker claim/retry/deduplication;
- migration order и schema contract;
- rate-limit bounds и enumeration resistance.

Команды:

```bash
cd backend-rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo audit
cargo deny check
```

`cargo deny` может сообщать предупреждения о нескольких transitive versions. Новый duplicate
допускается только при объяснимом dependency graph и отсутствии advisory/license проблемы.

## 4. iOS unit tests

Unit target `messengerTests` использует protocol-based doubles и in-memory secure stores. Тесты не
должны зависеть от production API или реального Keychain access, кроме явно выделенных integration
границ.

```bash
xcodebuild test \
  -project messenger/messenger.xcodeproj \
  -scheme messenger \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -only-testing:messengerTests
```

Keychain tests требуют обычной simulator code signing. `CODE_SIGNING_ALLOWED=NO` допустим для build
smoke, но не является корректным режимом полного unit suite.

## 5. UI и physical tests

UI tests разделены на две группы:

- deterministic smoke с synthetic state;
- physical regressions с реальным backend, APNs, CallKit и двумя устройствами.

Runtime config physical tests содержит disposable handles и seed-фразы, поэтому файл
`dual_iphone_runtime_config.json` всегда исключён из Git. Test source читает значения только через
environment/config file и пропускает сценарий при отсутствии обязательных параметров.

Physical run должен сохранять:

- `.xcresult` обоих устройств;
- sanitized JSONL diagnostics;
- скриншоты ключевых фаз;
- идентификатор scenario и итоговый pass/fail summary;
- server health/log window без credentials.

## 6. Security-oriented cases

Минимальный negative coverage:

- неверная registration/device/federation signature;
- expired/reused challenge;
- revoked device/session;
- изменение certificate parent;
- повтор consumed one-time prekey;
- message target другого device/account;
- media upload с неверным capability/hash/attestation;
- plaintext call event в WebSocket;
- oversized batch, TTL или skip window;
- push payload с запрещёнными identity fields.

## 7. Coverage

Code coverage используется как диагностический сигнал. Процент сам по себе не является release
gate: security-critical ветка с negative case важнее общего роста line coverage.

Для iOS coverage включён в shared `ProductionCalls.xctestplan`. В CI `.xcresult` сохраняется при
неуспешном запуске, чтобы review не ограничивался консольным tail.

## 8. Release gates

Release candidate считается проверенным, если:

1. Rust fmt/clippy/test/audit/deny успешны;
2. iOS unit suite успешен на закреплённой Xcode/iOS runtime;
3. docs site собирается в strict mode, локальные ссылки доступны, а русская и английская
   структуры синхронизированы;
4. secret scan не находит credential в reachable history;
5. local Compose стартует с чистыми volumes;
6. затронутые physical scenarios имеют свежий evidence;
7. ограничения и skipped tests перечислены в release notes.

## 9. Проверка опубликованной инструкции

Сценарий `scripts/remote-public-install-smoke.sh` копирует только публичный installation contract в
новый временный каталог удалённого Linux-сервера. Он назначает отдельные project name, порты и
volumes, поэтому не использует данные уже работающей инсталляции. Проверяются:

- валидация production environment;
- сборка backend image и запуск всего Compose stack;
- автоматическая выдача локального TLS-сертификата Caddy;
- `/health`, `/api/config` и применение миграций;
- аутентифицированный TURN relay по UDP и TCP;
- отсутствие unhealthy-контейнеров;
- удаление тестовых контейнеров, volumes и временного каталога.

Запуск выполняется только на специально выделенном Linux host с Docker:

```bash
TELLME_REMOTE_SSH_HOST=<ssh-alias> \
  bash scripts/remote-public-install-smoke.sh
```

Для проверки именно пользовательского пути отдельно следует повторить команды из раздела
«Быстрый локальный запуск» в `README.md` из чистого каталога. Результат и ограничения фиксируются в
release notes; наличие успешного внутреннего production health check не заменяет этот прогон.

## 10. Правила исправления flaky test

Flaky test не отключается без зафиксированного технического обоснования. Сначала классифицируется
источник:

- race/state leak;
- simulator/Keychain signing;
- network/provider dependency;
- physical device transport;
- неверный timeout;
- test data collision.

Допустимое исправление устраняет источник nondeterminism или переводит внешний dependency в
явный integration gate. Простое увеличение timeout без измерения причины не считается достаточным.
