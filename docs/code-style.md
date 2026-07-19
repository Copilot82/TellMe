# Стиль кода и комментариев

## 1. Общий принцип

Код должен делать инварианты видимыми через типы, границы модулей и тесты. Комментарий применяется
для причины или ограничения, которое невозможно выразить конструкцией языка.

## 2. Rust

- форматирование — rustfmt;
- `unsafe_code = forbid`;
- Clippy `all`, `pedantic`, `nursery`, `cargo` — deny;
- запрещены `unwrap`, `expect`, `panic`, `todo`, `unimplemented`, `dbg!` и stdout/stderr debug;
- public types/functions имеют rustdoc, если их contract не очевиден из имени;
- error type не содержит secret или необрезанный provider response;
- repository принимает нормализованные values и использует parameterized SQL.

## 3. Swift

- 2 пробела, одна декларация ответственности на тип;
- explicit type у nontrivial local values и публичных signatures;
- dependency injection через initializer/protocol;
- UI state меняется на main actor/thread boundary;
- Keychain/storage/network abstractions не подменяются глобальными singleton в tests;
- wire coding strategy централизована и не меняется локально без contract test.

## 4. Комментарии

Хороший комментарий отвечает минимум на один вопрос:

- какой security/privacy invariant защищает код;
- почему очевидное упрощение неверно;
- какая внешняя совместимость требует текущую форму;
- почему установлен конкретный bound/timeout/order;
- что должно оставаться атомарным относительно persistence.

Пример rationale-комментария:

```swift
// Ratchet operations return a new state instead of mutating storage so callers decide
// whether decrypted content and the advanced state are persisted atomically.
```

Нежелательный комментарий:

```swift
// Increment counter by one.
counter += 1
```

## 5. Документирование public contract

Rustdoc/Swift documentation comment должен содержать:

- назначение;
- важные preconditions;
- security-sensitive side effects;
- тип отказа, если он не очевиден;
- ссылку на protocol/ADR только когда без неё contract неполон.

## 6. Review checklist

- Нет ли комментария, который уже расходится с кодом?
- Можно ли заменить комментарий более точным именем или типом?
- Объяснён ли порядок операций при cryptographic/storage transition?
- Не попал ли в example действующий domain credential, token или seed?
- Есть ли test, подтверждающий заявленный invariant?
