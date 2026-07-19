# Architecture Decision Records

ADR фиксирует решение, которое влияет на несколько компонентов или изменяет долгоживущий contract.
После принятия ADR не переписывается задним числом: новое решение создаёт новый документ и явно
заменяет предыдущий.

## Индекс

| ADR | Статус | Решение |
| --- | --- | --- |
| [0001](0001-server-blind-storage.md) | принято | server-blind storage и routing envelope |
| [0002](0002-per-device-encryption.md) | принято | отдельное шифрование на устройство |
| [0003](0003-rust-backend.md) | принято | Rust/Axum как основной backend runtime |
| [0004](0004-realtime-is-not-source-of-truth.md) | принято | realtime как ускорение mailbox sync |

## Шаблон

```text
# ADR-NNNN: Краткое решение

Статус: предложено | принято | заменено | отклонено
Дата: YYYY-MM-DD

## Контекст
## Решение
## Последствия
## Проверка
```
