# ADR-0003: Rust/Axum как основной backend runtime

Статус: принято

Дата: 2026-07-06

## Контекст

Backend обрабатывает boundary-sensitive parsing, signatures, token/session state, worker claims и
media/federation transports. Ошибка типа, unchecked optional или неконтролируемый panic усложняет
сохранение protocol invariants.

## Решение

Основной server runtime реализуется на Rust 2021 с Axum, Tokio, SQLx и Serde. Workspace запрещает
unsafe code и включает строгие Clippy groups. Wire contract фиксируется типами и executable route
checklist.

## Последствия

Положительные:

- compile-time контроль ownership/concurrency;
- typed request/response и repository boundaries;
- единый бинарный artifact;
- строгая политика ошибок и отсутствие runtime dependency manager.

Отрицательные:

- более высокая стоимость изменения для разработчика без Rust опыта;
- `lib.rs` временно остаётся крупным composition/adapter layer;
- часть ecosystem integrations требует собственной реализации.

## Проверка

- `cargo fmt`, Clippy и 220 unit tests выполняются в CI;
- `cargo audit` и `cargo deny` проверяют dependencies/licenses;
- migrations и iOS-required routes покрыты contract tests.
