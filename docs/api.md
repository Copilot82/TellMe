# HTTP и WebSocket API

## 1. Общие правила

- Base URL клиента: `/api`.
- Формат тела: JSON, кроме бинарной загрузки media ciphertext.
- Имена JSON fields: `snake_case`.
- Ошибка: `{ "error": "message" }`.
- Session authentication: `Authorization: Bearer <session_token>`.
- Federation authentication: подписанные `X-TellMe-*` headers.
- Query/body size и batch bounds проверяются до вызова repository.

API ниже является обзором surface. Точный request schema зафиксирован Rust types и XCTest contract
tests. Изменение endpoint без обновления `contract.rs` считается ошибкой.

## 2. Системные endpoints

| Method | Path | Authentication | Назначение |
| --- | --- | --- | --- |
| `GET` | `/health` | нет | process health |
| `GET` | `/ready` | нет | readiness текущей реализации |
| `GET` | `/api/config` | нет | публичные protocol/server limits |

## 3. Authentication

| Method | Path | Authentication | Назначение |
| --- | --- | --- | --- |
| `POST` | `/api/auth/register` | registration proof | account и первое устройство |
| `POST` | `/api/auth/start` | нет | одноразовый challenge |
| `POST` | `/api/auth/finish` | device signature | session/refresh pair |
| `POST` | `/api/auth/refresh` | refresh token | rotation session pair |
| `POST` | `/api/auth/logout` | session/refresh | revoke session |

`auth/start` не должен использовать разные ответы для существующего и отсутствующего аккаунта,
если это позволяет построить public account enumeration oracle.

## 4. Devices и linking

| Method | Path | Назначение |
| --- | --- | --- |
| `POST` | `/api/devices/register` | регистрация device certificate |
| `POST` | `/api/devices/revoke` | отзыв устройства по подписанному proof |
| `POST` | `/api/devices/link/start` | создание trusted-device link session |
| `POST` | `/api/devices/link/request` | запрос нового устройства |
| `GET` | `/api/devices/link/session/:sessionId/requests` | pending requests trusted device |
| `GET` | `/api/devices/link/request/:requestId` | polling статуса с poll token |
| `POST` | `/api/devices/link/approve` | device certificate и encrypted provisioning |
| `POST` | `/api/devices/link/complete` | завершение и выдача tokens новому устройству |
| `GET` | `/api/devices/push/tokens` | список token metadata текущего устройства |
| `POST` | `/api/devices/push/tokens` | upsert alert/VoIP token |
| `PUT` | `/api/devices/push/tokens/:token` | изменение push mode/state |
| `DELETE` | `/api/devices/push/tokens/:token` | удаление token |

Raw APNs token не возвращается другому аккаунту или устройству. Token value не должен попадать в
application logs.

## 5. Prekeys

| Method | Path | Authentication | Назначение |
| --- | --- | --- | --- |
| `POST` | `/api/prekeys/publish` | session | signed/one-time prekeys текущего устройства |
| `GET` | `/api/prekeys/get?user=...&peek=...` | optional/session | public bundle адресата |
| `GET` | `/api/prekeys/self?peek=...` | session | bundles собственного аккаунта |

`peek=false` может атомарно consume one-time prekey. Повторный bundle не должен выдавать тот же
доступный OPK после успешного consume.

## 6. Messages и sync

| Method | Path | Назначение |
| --- | --- | --- |
| `POST` | `/api/messages/send` | batch per-device ciphertext deliveries |
| `POST` | `/api/messages/ack` | acknowledgement delivery ids текущего устройства |
| `GET` | `/api/sync/stream?device_id=...&limit=...` | pending mailbox blobs |

`limit` находится в диапазоне `1...1000`, default — `200`. Backend не интерпретирует содержимое
`ciphertext_blob` и не генерирует plaintext call/message fields.

## 7. Media

| Method | Path | Authentication | Назначение |
| --- | --- | --- | --- |
| `POST` | `/api/media/upload/init` | session | media id и download capability |
| `PUT` | `/api/media/upload/:id` | capability + attestation | ciphertext upload |
| `GET` | `/api/media/ciphertext/:id` | capability | ciphertext download |

Upload проверяет capability, declared size, ciphertext hash, scanner/rules version и attestation.
Download никогда не возвращает media key.

## 8. TURN

| Method | Path | Authentication | Назначение |
| --- | --- | --- | --- |
| `POST` | `/api/turn/credentials` | session | ephemeral TURN username/password и URLs |

Request не принимает user handle, peer id, conversation id или call id. TTL новой allocation
ограничен `60...900` секундами.

## 9. Federation

| Method | Path | Authentication | Назначение |
| --- | --- | --- | --- |
| `GET` | `/federation/v1/server-keys` | нет/transport policy | public server key metadata |
| `GET` | `/federation/v1/prekeys/:userHandle` | signed request | remote prekey lookup |
| `POST` | `/federation/v1/deliver` | signed request | remote ciphertext delivery |
| `POST` | `/federation/v1/receipts` | signed request | delivery receipts |

Canonical signature связывает HTTP method, path, timestamp и SHA-256 body hash. Unknown, blocked,
expired или неверно подписанный server request отклоняется до domain processing.

## 10. WebSocket

Transport endpoint: `/socket.io/?EIO=4&transport=websocket`.

Session token передаётся в Socket.IO connect auth, а не query string. Realtime является механизмом
уведомления и ускорения sync; источник истины для pending delivery остаётся PostgreSQL mailbox.

### Client events

| Event | Назначение |
| --- | --- |
| `sync_subscribe` | подписка текущего device mailbox |
| `sync_pull` | запрос blobs, optional bounded limit |
| `presence_touch` | обновление краткоживущего presence |
| `join_conversation` | active-conversation hint без server chat membership |
| `leave_conversation` | удаление active hint |
| `presence_offline` | принудительный offline override |

### Server events

| Event | Payload |
| --- | --- |
| `sync_blobs` | batch pending ciphertext blobs |
| `sync_blob_available` | message/delivery/device identifiers без ciphertext |
| `device_link_request` | request id и new device id |
| `device_link_approved` | request id |

Plaintext call signaling events запрещены protocol v2.

## 11. Rate limits

Отдельные fixed-window limits применяются как минимум к authentication, public directory/prekeys,
federation pre-auth, authenticated federation, media и TURN credentials. Retry response использует
HTTP `429` и не должен раскрывать существование аккаунта через различия policy.
