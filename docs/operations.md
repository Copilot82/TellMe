# Эксплуатационная модель

## 1. Назначение документа

Документ описывает runtime contract без production IP, SSH aliases и credentials. Воспроизводимый
одноузловой контур находится в `compose.production.yml`; пошаговая установка приведена в
[deployment.md](deployment.md). Конкретные secrets и адреса остаются вне Git.

## 2. Runtime components

| Компонент | Ответственность | Persistent data |
| --- | --- | --- |
| Rust server | HTTP/WebSocket, migrations, workers | нет локального state |
| PostgreSQL | account/device/mailbox/job metadata | да |
| Redis | presence и realtime coordination | ограниченно |
| MinIO/S3 | media ciphertext | да |
| TLS proxy | TLS termination и HTTP routing | certificates вне repo |
| coturn | STUN/TURN relay | ephemeral allocations |
| APNs | remote wake provider | внешний сервис |

## 3. Конфигурация

Production configuration поступает только через environment/secret files вне Git. Обязательные
секреты не имеют fallback, пригодного для production:

- session и refresh signing secrets;
- federation signing private key;
- TURN shared secret;
- MinIO credentials;
- APNs `.p8` или base64 key material.

`SERVER_DOMAIN`, public URLs и limits относятся к runtime contract, но не являются secret.

## 4. Startup sequence

1. Infrastructure dependencies достигают health state.
2. Server загружает и валидирует environment.
3. PostgreSQL pool устанавливает соединение с bounded retry.
4. Pending migrations применяются по фиксированному списку.
5. HTTP listener начинает принимать трафик.
6. Worker scheduler запускается только при `TELLME_RUST_WORKERS_ENABLED=true`.

Отсутствующая обязательная конфигурация должна приводить к явному startup failure, а не к запуску
в частично защищённом режиме.

## 5. Health и readiness

- `/health` подтверждает работоспособность процесса и стабильность wire response;
- `/ready` используется как readiness endpoint текущего runtime;
- внешний monitor дополнительно проверяет TLS route и dependency-backed smoke.

Process health не доказывает готовность каждого protocol domain. Release validation должна
включать database migration и хотя бы один authenticated contract smoke.

## 6. Workers

Outbox, push и cleanup jobs резервируются с claim token и timestamp. Повторный worker не должен
обрабатывать активный claim до истечения TTL. Ошибка provider классифицируется как retryable или
terminal; error detail ограничивается по размеру и не содержит payload/credential.

Media cleanup сначала удаляет object ciphertext, затем metadata. При ошибке object storage metadata
сохраняется для повторной попытки, чтобы не потерять ссылку на orphan object.

## 7. Deployment и rollback

Production deployment должен быть атомарным на уровне application image:

1. build candidate из конкретного commit;
2. запуск candidate с текущим external state;
3. health/readiness и contract smoke;
4. переключение active service;
5. promotion image только после успешной проверки;
6. rollback на предыдущий image при неуспехе.

Database migration обязана быть backward-compatible с предыдущим application image либо иметь
отдельно документированный irreversible gate. Destructive migration не должна выполняться как
неявная часть ordinary restart.

## 8. Observability

Рекомендуемые metrics:

- HTTP requests по route/status/latency без user handle;
- active WebSocket sessions и reconnect rate;
- mailbox pending/expired/acked counts;
- outbox/push queue age и retry count;
- media upload verdict/rejection category;
- database pool saturation;
- worker cycle duration;
- federation request status по domain без payload.

Logs используют correlation/job/delivery id, но не message ciphertext целиком. Security logging
ограничения определены в `threat-model.md`.

## 9. Backup и recovery

Backup scope включает PostgreSQL и media ciphertext storage. Redis presence можно восстановить как
ephemeral state. Backup не повышает confidentiality: он содержит те же routing metadata и
ciphertext, поэтому encrypt-at-rest, access control и retention обязательны.

Recovery exercise должен проверять:

- восстановление schema migrations;
- согласованность media metadata и objects;
- отсутствие повторной отправки terminal jobs;
- возможность клиента продолжить sync по существующим session/device records.

## 10. Incident priorities

1. Утечка private provider/server signing key — немедленная rotation и revoke.
2. Возможность получить plaintext — остановка затронутого route и coordinated disclosure.
3. Нарушение device trust/auth — revoke sessions/devices и protocol analysis.
4. Потеря ciphertext/availability — остановка destructive worker и recovery.
5. Metadata exposure — ограничение доступа, retention review и уведомление по применимой политике.
