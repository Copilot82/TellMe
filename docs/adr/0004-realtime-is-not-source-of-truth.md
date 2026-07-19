# ADR-0004: Realtime не является источником истины

Статус: принято

Дата: 2026-07-06

## Контекст

WebSocket соединение на мобильном устройстве прерывается при background transition, смене сети и
энергосбережении. Если message delivery зависит от успешного realtime event, потеря соединения
приводит к потере данных или сложной replay логике.

## Решение

PostgreSQL mailbox является источником истины для pending ciphertext. WebSocket отправляет
availability events и может вернуть sync batch, но клиент всегда способен восстановить состояние
через REST sync. APNs также сообщает только о необходимости синхронизации.

## Последствия

Положительные:

- disconnect не теряет delivery;
- REST и realtime используют один mailbox contract;
- push payload не содержит message plaintext;
- acknowledgement остаётся явным и идемпотентным.

Отрицательные:

- возможен лишний REST pull после reconnect/push;
- presence имеет eventual consistency;
- UI должен дедуплицировать deliveries по id.

## Проверка

- realtime event не содержит ciphertext/body;
- reconnect controller запускает mailbox sync;
- delivery id уникален для target mailbox;
- offline/presence tests не создают conversation state на сервере.
