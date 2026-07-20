# Проверка production-установки

## 1. Правило приёмки

Проверка выполняется после первого запуска, обновления image, изменения DNS/TLS, APNs или TURN.
`/health` сам по себе недостаточен: он не доказывает WebSocket upgrade, migrations, object storage,
APNs и relay traffic.

Сохраните дату, commit hash, image IDs и результат каждого раздела во внутреннем change record.
Секреты, device tokens, seed-фразы и полный ciphertext в отчёт не включаются.

## 2. Контейнеры

```bash
cd /opt/tellme/app
sudo docker compose --env-file .env.production -f compose.production.yml ps
sudo docker compose --env-file .env.production -f compose.production.yml images
```

Критерии:

- `postgres`, `redis`, `minio`, `server`, `coturn` — `healthy`;
- `caddy` — `running`;
- отсутствуют restart loop и неожиданно опубликованные database/storage ports.

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

## 3. DNS и TLS

```bash
dig +short A chat.corp.example
curl --fail --show-error --verbose https://chat.corp.example/health
openssl s_client -servername chat.corp.example -connect chat.corp.example:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256
```

Критерии: DNS содержит address VPS, certificate chain доверен системе, SAN включает домен,
`notAfter` находится в будущем, HTTP status — `200`, body содержит `"status":"ok"`.

## 4. API и WebSocket

```bash
curl --fail --show-error https://chat.corp.example/ready
curl --fail --show-error https://chat.corp.example/api/config
```

`/api/config` должен возвращать production domain, wire/protocol versions и
`"call_signaling":"e2e_message_payload"`. TURN URLs проверяются отдельно через credentials route
в клиентском сценарии и прямой allocation test из раздела 7; публичный config их не раскрывает.

```bash
curl --http1.1 --include --no-buffer --max-time 5 \
  'https://chat.corp.example/socket.io/?EIO=4&transport=websocket' \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
```

Критерий — `101 Switching Protocols`. Завершение `curl` по timeout после upgrade не является
ошибкой этой проверки.

## 5. Database migrations

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T postgres \
  sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM schema_migrations;"'
```

Для версии `2.0.0` ожидается не менее 16 применённых migrations. Дополнительно проверьте, что
`server` log не содержит migration error или повторяющегося startup failure.

## 6. MinIO

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T minio \
  curl --fail http://127.0.0.1:9000/minio/health/ready
```

Затем отправьте из iOS тестовое вложение, скачайте его на втором устройстве и подтвердите:

- server сохранил object;
- получатель расшифровал файл;
- прямой неавторизованный запрос к MinIO снаружи невозможен;
- plaintext имя/содержимое не появились в container logs.

## 7. TURN UDP и TCP

Не выводите `TURN_STATIC_SECRET`. Передайте его только внутри shell контейнера:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml exec -T coturn \
  sh -lc '
    turnutils_uclient -c -I -Y alloc -n 1 -m 1 \
      -u healthcheck -W "$TURN_STATIC_SECRET" \
      -p "$TURN_LISTENING_PORT" "$TURN_EXTERNAL_IP" >/dev/null &&
    turnutils_uclient -t -c -I -Y alloc -n 1 -m 1 \
      -u healthcheck -W "$TURN_STATIC_SECRET" \
      -p "$TURN_LISTENING_PORT" "$TURN_EXTERNAL_IP" >/dev/null
  '
```

Exit code `0` подтверждает authenticated allocation по UDP и TCP с текущим shared secret. Это не
заменяет проверку снаружи: выполните видеозвонок между двумя физическими устройствами в разных
сетях и убедитесь, что relay candidates используются при недоступном direct path.

```bash
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --since=10m coturn
```

Ошибки `no available ports` означают исчерпание/блокировку relay range, а `401/438` при длительной
сессии требуют проверки clock и credential TTL.

## 8. APNs

Проверка проводится отдельно для Debug development token и TestFlight production token.

1. Запустите приложение и разрешите уведомления.
2. Убедитесь, что device зарегистрировал alert и VoIP tokens.
3. Переведите приложение в background и отправьте сообщение со второго устройства.
4. Заблокируйте экран и инициируйте вызов.
5. Проверьте generic notification без plaintext и появление CallKit UI.
6. Просмотрите ограниченный server log worker за соответствующий интервал.

Критерии: нет `InvalidProviderToken`, `DeviceTokenNotForTopic`, `BadDeviceToken`; push job не
остаётся в бесконечном retry; уведомление не раскрывает текст сообщения или identity вызывающего.

## 9. Клиентский end-to-end сценарий

На двух физических устройствах:

1. создайте разные тестовые учётные записи;
2. обменяйтесь текстовыми сообщениями;
3. переведите получателя offline, отправьте сообщение и проверьте mailbox sync после возврата;
4. отправьте изображение и файл;
5. выполните audio call, video call и Picture in Picture;
6. повторите call при разных сетях;
7. отзовите дополнительное устройство и убедитесь, что оно исключено из последующего fanout.

Не используйте персональные или рабочие данные в acceptance-сценарии.

## 10. Backup и restore

Создайте backup и восстановите его в отдельный временный Compose project по процедуре
[backup-and-restore.md](backup-and-restore.md). Backup, который никогда не восстанавливался, не
считается проверенным.

## 11. Итоговый протокол

| Gate | Обязательный результат |
| --- | --- |
| Containers | все runtime services стабильны |
| TLS | валидный chain и correct hostname |
| REST/ready | HTTP 200 и ожидаемый JSON |
| WebSocket | HTTP 101 |
| Migrations | полный упорядоченный набор |
| Media | upload/download/decrypt на клиентах |
| TURN | authenticated UDP и TCP allocation |
| APNs | alert и VoIP delivery |
| E2E | message, offline sync, media, call, revoke |
| Recovery | успешное изолированное восстановление |

Production acceptance завершается только если все gates имеют доказуемый результат либо формально
принятое исключение с владельцем риска и сроком устранения.
