# Протокол TellMe v2

## 1. Термины

| Термин | Значение |
| --- | --- |
| Account identity | долговременная Ed25519/X25519 identity аккаунта |
| Device identity | отдельная signing/DH identity устройства |
| Device certificate | подписанная связь device keys с account identity или trusted device |
| Signed prekey | среднесрочный X25519 public key с подписью устройства |
| One-time prekey | одноразовый X25519 public key для первого согласования |
| Ratchet session | локальное root/chain/counter state пары устройств |
| Routing envelope | серверно-видимые поля доставки |
| Encrypted payload | заголовок и body, доступные только участникам |

Wire fields используют `snake_case`. User handle нормализуется к форме `@login:domain`.

## 2. Ключевой материал

На первом устройстве клиент создаёт seed и производит account/device key material. Private values
не передаются backend. Сервер получает:

- `ik_sign_pub`, `ik_dh_pub`;
- `dk_sign_pub`, `dk_dh_pub`;
- registration proof;
- device certificate chain;
- signed prekey и one-time prekeys.

Private values сохраняются в account-scoped Keychain storage. Ratchet state и local archive также
не синхронизируются как plaintext server state.

## 3. Регистрация и вход

### Регистрация

1. Клиент формирует canonical registration payload с user handle, public identity keys и timestamp.
2. Payload подписывается account signing key.
3. Backend проверяет timestamp skew, подпись и уникальность identity.
4. Первый device certificate проверяется относительно account identity.
5. Backend создаёт account/device records и session/refresh pair.

Повтор регистрации допустим только для того же account/device contract. Изменение ключей
существующего аккаунта не интерпретируется как обычный retry.

### Вход

```text
client -> POST /api/auth/start  { user_handle, device_id }
server -> challenge_id, nonce, expires_at
client -> POST /api/auth/finish { challenge_id, device_id, signature }
server -> session_token, refresh_token
```

Nonce одноразовый и ограничен сроком жизни. Finish разрешён только активному зарегистрированному
устройству. Refresh token вращается; logout/revoke переводит соответствующую server session в
неактивное состояние.

## 4. Prekeys и старт E2E-сессии

Устройство публикует один signed prekey и набор one-time prekeys. Backend атомарно выдаёт и
помечает one-time prekey использованным, если запрос не является `peek`.

Для первого сообщения инициатор вычисляет X25519 shared secrets:

```text
DH1 = DH(IK_A, SPK_B)
DH2 = DH(EK_A, IK_B)
DH3 = DH(EK_A, SPK_B)
DH4 = DH(EK_A, OPK_B)  // если OPK присутствует
```

Материал объединяется и подаётся в HKDF-SHA256 с protocol-specific `info`. Результат создаёт
initial root/chain state. Первое сообщение содержит только публичные bootstrap fields,
необходимые получателю для симметричного вычисления того же секрета.

Эта реализация следует структуре X3DH, но не заявляется как формально совместимая с Signal
Protocol и не проходила независимый аудит.

## 5. Double Ratchet

Каждая пара устройств хранит отдельное состояние:

- `root_key`;
- send/receive chain keys;
- send/receive counters;
- local/remote ratchet public keys;
- bounded cache пропущенных message keys.

Для каждого сообщения KDF chain выводит message key и следующий chain key. Старый chain key не
используется повторно. При смене remote ratchet public key выполняется DH ratchet и создаются новые
receive/send chains.

Skip window ограничен 128 сообщениями. Ограничение защищает client memory от неограниченного
создания skipped keys при вредоносном индексе. Уже использованный или слишком старый индекс
отклоняется.

## 6. Формат сообщения

Backend получает delivery со следующими категориями полей:

```text
message_id, delivery_id
target user/server/device
ttl
ciphertext_blob
opaque push routing class
```

`ciphertext_blob` содержит protocol version, envelope kind, session id, публичные ratchet/bootstrap
fields и два AEAD ciphertext: encrypted header и encrypted body. Body authenticated data связывает
protocol version, kind, session id и header, чтобы не допустить перестановку частей envelope.

Message body, conversation semantics, attachment keys и call signaling находятся внутри encrypted
body.

## 7. Per-device fanout

Отправитель получает bundles всех активных устройств адресата и создаёт отдельный delivery на
каждое устройство. Собственные вторичные устройства отправителя получают self-sync copy по тому же
принципу.

Backend не строит plaintext membership list. Он разрешает target devices из account/device
records, исключая revoked state.

## 8. Синхронизация и acknowledgement

Mailbox является очередью encrypted blobs, а не message history:

1. REST `GET /api/sync/stream` или `sync_pull` возвращает pending blobs;
2. realtime `sync_blob_available` сообщает только о наличии новой записи;
3. клиент расшифровывает blob и сохраняет локальное состояние;
4. `POST /api/messages/ack` подтверждает delivery для текущего устройства;
5. TTL/cleanup удаляет истёкшие server records.

Acknowledgement отправляется после успешной локальной обработки. WebSocket event не заменяет REST
sync и может быть потерян без потери данных.

## 9. Подключение устройства

1. Trusted device создаёт короткоживущую link session и QR payload.
2. New device отправляет ephemeral DH public key и собственные device public keys.
3. Trusted device получает request через REST/realtime, проверяет пользователя и подписывает device
   certificate.
4. Provisioning data шифруется на ephemeral shared secret.
5. New device завершает linking по one-time poll token.

Link code и poll token сохраняются в backend только как hashes. Одобрение не передаёт account
private key в открытом виде.

## 10. Вложения

Клиент создаёт случайный media key, шифрует файл локально и вычисляет ciphertext hash. Backend
выдаёт media id и capability, принимает ciphertext с device attestation и сохраняет capability
только как hash.

В encrypted message payload передаются media id, origin server, media key, hashes и необходимые
metadata. Получатель проверяет ciphertext hash до расшифрования и применяет local inspection policy
перед открытием.

## 11. Звонки

Offer, answer, ICE candidates и call state кодируются как E2E message payload. Legacy plaintext
Socket.IO events `call_offer`, `call_ice_candidate` и `call_media_state` явно отклоняются.

Backend выдаёт краткоживущие TURN credentials без user, peer, conversation или call identifier.
Opaque VoIP wake сообщает устройству о необходимости mailbox sync, но не раскрывает call metadata
в APNs payload.

## 12. Федерация

Server-to-server request содержит key id, timestamp, body hash и signature над canonical request.
Получатель проверяет known server key/trust state, timestamp и подпись до передачи в domain service.

Remote deliver не даёт отправляющему серверу права читать mailbox или выполнять user session
операции. Rate limits разделены для pre-auth discovery и authenticated federation traffic.

## 13. Версионирование

Protocol-breaking изменение требует:

- нового version field или явно описанного hard cutover;
- обновления contract tests iOS/backend;
- migration plan для local ratchet state и server schema;
- отдельного ADR;
- обновления threat model.
