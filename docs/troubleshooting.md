# Диагностика установки

## 1. Сбор минимального контекста

Начните с команд, которые не раскрывают значения environment:

```bash
cd /opt/tellme/app
git rev-parse HEAD
sudo docker version
sudo docker compose version
sudo docker compose --env-file .env.production -f compose.production.yml ps
sudo docker compose --env-file .env.production -f compose.production.yml images
sudo ss -lntup | grep -E ':(80|443|3100|3478|5349)\b' || true
```

Логи ограничивайте сервисом и временем:

```bash
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --since=15m --tail=300 server
```

Не публикуйте `.env.production`, APNs key, `docker inspect` environment, device tokens, seed-фразы
или полный production log.

## 2. Compose не проходит validation

| Симптом | Причина | Действие |
| --- | --- | --- |
| `template values` | остались `example.com`/`203.0.113.10`/`CHANGE_ME` | заполнить `.env.production` |
| `Required variable is empty` | отсутствует обязательный contract | сравнить с `.env.production.example` |
| APNs key unavailable | `APNS_ENABLED=true`, но key не смонтирован | установить `secrets/apns/AuthKey.p8` с mode `0600` |
| port is already allocated | listener занят другим process/container | определить владельца через `ss` и `docker ps`; не менять порты вслепую |

После исправления всегда повторяйте:

```bash
sudo env TELLME_PRODUCTION_ENV_PATH="$PWD/.env.production" \
  bash scripts/validate-production-config.sh
```

## 3. Server не становится healthy

```bash
sudo docker compose --env-file .env.production -f compose.production.yml ps server postgres redis minio
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --tail=300 server postgres redis minio
```

Типовые причины:

- PostgreSQL ещё не ready или пароль не совпадает с уже созданным volume;
- `.env.production` изменён после первого инициализирования PostgreSQL;
- MinIO credentials изменены без миграции существующего volume;
- `SERVER_SIGN_PRIVATE_KEY` не является base64 от 32-байтового seed;
- APNs включён с неполной конфигурацией;
- VPS исчерпал RAM или disk во время build/migrations.

Изменение `POSTGRES_PASSWORD` в environment не меняет пароль внутри существующего database volume.
Восстановите прежнее значение либо выполните контролируемую rotation в PostgreSQL. Не удаляйте
volume как способ исправить production.

## 4. Caddy не получает certificate

```bash
dig +short A chat.corp.example
curl -I http://chat.corp.example
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --tail=300 caddy
```

Проверьте:

- DNS указывает на этот VPS;
- TCP `80/443` разрешены у провайдера и не заняты другим proxy;
- AAAA не указывает на ненастроенный IPv6;
- CDN proxy временно отключён;
- ACME rate limit не исчерпан повторными попытками.

Caddy data хранится в volume `tellme_caddy_data`; его удаление вызывает новую выдачу certificate и
не должно использоваться как обычный troubleshooting step.

## 5. WebSocket не получает 101

REST может работать при неверной WebSocket-конфигурации. Выполните команду из
[deployment-verification.md](deployment-verification.md). Проверьте точный path `/socket.io/`,
query `EIO=4&transport=websocket` и HTTP/1.1 upgrade headers.

Если перед Caddy расположен CDN/load balancer, он должен пропускать `Upgrade` и `Connection` и не
обрывать долгоживущие соединения. Для первичной проверки подключайтесь к VPS напрямую.

## 6. TURN allocation не работает

```bash
sudo docker compose --env-file .env.production -f compose.production.yml ps coturn
sudo docker compose --env-file .env.production -f compose.production.yml logs \
  --no-color --since=15m coturn
sudo ss -lnup | grep ':3478\b' || true
```

| Сообщение/симптом | Проверка |
| --- | --- |
| `no available ports` | открыт и свободен ли весь `TURN_MIN_PORT–TURN_MAX_PORT`; нет ли исчерпания allocations |
| allocation работает внутри, но не снаружи | provider firewall, NAT mapping, public/private IP pair |
| `401 Unauthorized` | backend и coturn используют разные `TURN_STATIC_SECRET` либо credential просрочен |
| `438 Stale Nonce` | clock drift, длительная повторная попытка клиента |
| звонок работает только в одной сети | relay UDP range или TCP fallback недоступен |

Проверьте синхронизацию времени `timedatectl status`. После rotation TURN secret одновременно
пересоздайте `server` и `coturn`; иначе backend выдаёт credentials, которые relay отвергает.

## 7. APNs возвращает ошибку

| APNs reason | Вероятная причина |
| --- | --- |
| `InvalidProviderToken` | неверный `.p8`, Key ID, Team ID или подпись |
| `ExpiredProviderToken` | часы VPS неверны или provider JWT слишком старый |
| `BadDeviceToken` | token относится к другому APNs environment |
| `DeviceTokenNotForTopic` | `APNS_BUNDLE_ID` не совпадает с подписанным app |
| `Unregistered` | приложение удалено либо token больше не активен |

Сначала сравните Release build settings и `.env.production`, не выводя token/key. Официальные
значения status/reason: [APNs responses](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).

## 8. iOS подключается к старому домену

Production Archive не использует environment variables scheme. Проверьте встроенные Build
Settings:

```bash
xcodebuild -project messenger/messenger.xcodeproj -scheme messenger \
  -configuration Release -showBuildSettings \
  | grep -E 'PRODUCT_BUNDLE_IDENTIFIER|TELLME_(API|WS|TURN|STUN|APP_)'
```

Очистите DerivedData только после подтверждения settings, затем создайте новый Archive. Номер build
в App Store Connect должен отличаться от уже загруженного.

## 9. Certificate pin блокирует сеть

Если system TLS через `curl` работает, а приложение получает trust/cancel error, сравните SHA-256
leaf certificate с `TELLME_API_PRIMARY_CERT_SHA256` и backup pin. При плановом renewal клиент должен
заранее содержать pin следующего certificate.

Не отключайте TLS verification. Если формализованного процесса pin rotation нет, выпустите новую
сборку с пустыми pin settings, используя системный trust store.

## 10. Безопасная остановка

```bash
sudo docker compose --env-file .env.production -f compose.production.yml stop server caddy coturn
```

Эта команда сохраняет database и object volumes. `down --volumes`, `docker volume rm` и ручное
удаление `/var/lib/docker` необратимы и не относятся к обычной диагностике.
