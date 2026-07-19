# Модель угроз

## 1. Цель

Модель фиксирует security claims TellMe protocol v2. Она описывает ожидаемые свойства системы, но
не заменяет независимый аудит реализации.

## 2. Защищаемые активы

| Актив | Требуемое свойство |
| --- | --- |
| Message plaintext | confidentiality и integrity между устройствами |
| Attachment plaintext и media key | confidentiality вне устройства |
| Identity/device private keys | не покидают доверенное устройство в открытом виде |
| Ratchet state | confidentiality, rollback resistance в пределах local storage model |
| Call signaling | E2E confidentiality и integrity |
| Session/refresh token | защита от чтения в базе и повторного использования после revoke |
| Device trust graph | невозможность незаметно добавить устройство без доверенного подтверждения |
| Federation identity | невозможность подделать trusted server request |

## 3. Противник

Рассматриваются следующие возможности:

1. пассивное наблюдение сети вне TLS endpoint;
2. чтение базы, object storage и application logs;
3. полный контроль backend после компрометации;
4. отправка произвольных HTTP/WebSocket/federation запросов;
5. владение одним отозванным или скомпрометированным устройством;
6. попытка подменить public key при discovery;
7. повтор, задержка, удаление и перестановка ciphertext deliveries.

Не рассматриваются как полностью решённые:

- компрометация разблокированного устройства с доступом к process memory;
- уязвимость операционной системы или CryptoKit/WebRTC;
- глобальный анализ сетевого трафика;
- принуждение пользователя подтвердить вредоносное linking действие;
- denial of service со стороны контролирующего backend.

## 4. Security invariants

### SI-1. Server-blind content

Backend не получает ключ, позволяющий расшифровать message body, attachment или call signaling.
Нарушением считается любое новое server field, содержащее plaintext либо E2E symmetric key.

### SI-2. Per-device encryption

Delivery адресуется конкретному устройству. Revoked device не включается в новый fanout. Общий
payload key допустим только внутри схемы, где каждый device получает отдельную защищённую обёртку.

### SI-3. Auth без password-equivalent secret на сервере

Login использует challenge-response подпись действующего device key. Session/refresh tokens
хранятся как hashes и имеют expiry/revoke state.

### SI-4. Key continuity

Device certificate проверяется относительно account identity или доверенной цепочки. Смена identity
не должна приниматься как обычное обновление без пользовательского сигнала.

### SI-5. Ciphertext-only media

Object storage получает ciphertext. Capability хранится только как hash; media key находится в
encrypted payload.

### SI-6. Privacy-first push

APNs payload может сообщить о необходимости синхронизации, но не содержит sender, conversation,
message text и открытый call identifier.

## 5. Угрозы и меры

| Угроза | Возможное влияние | Реализованная мера | Остаточный риск |
| --- | --- | --- | --- |
| Чтение PostgreSQL | metadata и ciphertext disclosure | private keys отсутствуют; tokens hashed | traffic graph и timestamps видимы |
| Чтение MinIO | копирование вложений | client-side encryption | size/timing metadata |
| Server MITM key discovery | подмена будущего устройства | device signatures, certificates, verification UI | нет key transparency log |
| Replay delivery | повтор сообщения | delivery id, ratchet counter, ack state | DoS/задержка остаются возможны |
| Stolen refresh token | захват session | rotation, hashes, revoke, expiry | активный token действует до обнаружения |
| Malicious federation peer | spam, forged delivery | request signatures, trust state, rate limits | trust onboarding требует operator policy |
| Push payload disclosure | metadata leak у provider | opaque payload | device token и wake timing видимы |
| TURN operator | IP metadata | ephemeral credentials, E2E signaling | relay видит endpoints и объём трафика |
| Oversized/out-of-order message | resource exhaustion | validation bounds, skip window, rate limits | distributed DoS полностью не устранён |
| Malicious attachment | локальная эксплуатация viewer | inspection, blocked types, ciphertext hash | zero-day в viewer/OS |

## 6. Компрометация backend

Контролирующий backend может:

- остановить, задержать, удалить или дублировать доставку;
- собирать routing metadata;
- возвращать устаревшие или подменённые public bundles;
- блокировать revoke/linking requests;
- управлять availability событий и push timing.

Он не должен получать из server state:

- message/file/call plaintext;
- account/device private keys;
- ratchet root, chain или message keys;
- media keys;
- возможность создать действительную device/account signature.

Защита от активной подмены key discovery неполна без key transparency. Поэтому verified peer state
и предупреждение о смене identity рассматриваются как обязательная пользовательская граница, а не
как вспомогательная функция.

## 7. Logging policy

В production logs запрещены:

- Authorization header и session/refresh token;
- registration/link code и poll token;
- private/public key bundle целиком;
- ciphertext blob и media capability;
- APNs token и provider key;
- decrypted payload или seed phrase.

Разрешены bounded error category, route, status, duration, worker job id и агрегированные счётчики.
User handle и IP логируются только при обоснованной операционной необходимости и с ограниченным
retention.

## 8. Проверка модели

Каждый security invariant должен иметь хотя бы один negative test. Дополнительно CI выполняет
dependency audit и запрещающие lints. Независимый protocol review и external penetration test
остаются отдельными release gates для production-grade использования.
