# ADR-0001: Server-blind storage

Статус: принято

Дата: 2026-07-02

## Контекст

Messenger backend должен обеспечивать offline delivery, device fanout, media upload и push wake.
Хранение plaintext history упростило бы server features, но превратило бы компрометацию backend в
компрометацию всей переписки.

## Решение

Backend хранит routing envelope отдельно от encrypted payload. Message body, внутренние metadata
диалога, attachment key и call signaling шифруются клиентом. Server storage содержит только
public key material, per-device mailbox ciphertext, media ciphertext и минимальные routing fields.

## Последствия

Положительные:

- чтение PostgreSQL/MinIO не даёт message/file plaintext;
- federation server не получает ключи другого домена;
- server backup не содержит расшифрованную историю.

Отрицательные:

- server-side search/moderation по содержимому невозможны;
- часть metadata неизбежно видима для маршрутизации;
- удаление уже доставленного сообщения зависит от клиента;
- recovery ключей и истории сложнее.

## Проверка

- repository tests проверяют отсутствие plaintext fields в mailbox/push queries;
- legacy plaintext call routes отсутствуют в contract;
- media download возвращает только ciphertext;
- threat model перечисляет разрешённые server-visible fields.
