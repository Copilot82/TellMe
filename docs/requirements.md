# Требования к развёртыванию

## 1. Выбор сценария

Перед установкой определите требуемый результат. Наборы требований различаются.

| Сценарий | Что получится | Apple Developer | Домен и VPS |
| --- | --- | --- | --- |
| Просмотр beta | установка готовой TestFlight-сборки | не требуется | не требуются |
| Локальная разработка | backend на Mac/Linux и клиент в Simulator | не требуется для Simulator | не требуются |
| Запуск на собственном iPhone | development-сборка, подписанная вашей командой | требуется signing team; возможности бесплатного аккаунта ограничены | backend может быть локальным |
| Корпоративный экземпляр | собственный домен, APNs, TURN и TestFlight | активное платное членство обязательно | обязательны |

Открытая beta: [TestFlight](https://testflight.apple.com/join/qP7BxM1e). До завершения Apple
TestFlight App Review ссылка может не предоставлять доступ к сборке.

## 2. Apple и рабочая станция

Для собственного distribution-контура необходимы:

- активное членство организации в [Apple Developer Program](https://developer.apple.com/programs/enroll/);
- роль, позволяющая создавать identifiers, keys и приложение в App Store Connect;
- Mac с доступом в интернет и Xcode 26.2;
- Apple Account, добавленный в **Xcode → Settings → Accounts**;
- доступ к [App Store Connect](https://appstoreconnect.apple.com/);
- физический iPhone или iPad для проверки APNs, CallKit, камеры, микрофона и реального TURN.

Проект имеет deployment target iOS/iPadOS `15.0` и device family iPhone/iPad. CI и приведённые в
документации команды проверены с Xcode 26.2 и Simulator iOS 26.2. Более старый Xcode не входит в
документированный контур сборки версии `2.0.0`, даже если отдельные исходники компилируются.

Организации потребуются три уникальных identifier:

| Identifier | Пример | Назначение |
| --- | --- | --- |
| App ID | `com.company.tellme` | основной target и APNs topic |
| Extension App ID | `com.company.tellme.NotificationService` | Notification Service Extension |
| App Group | `group.com.company.tellme` | общий signing contract targets |

Для backend необходим APNs authentication key (`.p8`), его Key ID и Team ID. Apple предупреждает,
что приватный key-файл после создания нельзя скачать повторно; храните его как production secret.
Официальная последовательность: [создание private key](https://developer.apple.com/help/account/keys/create-a-private-key)
и [token-based APNs](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens/).

## 3. Домен и DNS

Нужен управляемый домен и отдельное полное доменное имя сервиса, например
`chat.corp.example`. Обязательные условия:

- A-запись указывает на публичный IPv4 VPS;
- AAAA-запись добавляется только при действительно настроенном IPv6;
- DNS-провайдер позволяет менять записи и TTL;
- TCP `80` и `443` доступны из интернета для выдачи и обновления TLS-сертификата;
- домен не находится за proxy-режимом CDN на этапе первичной диагностики;
- один и тот же FQDN внесён в `SERVER_DOMAIN`, iOS API/WebSocket endpoints и TURN URLs.

Один FQDN можно использовать и для HTTPS, и для TURN. Отдельный `turn.corp.example` допустим, но
тогда для него нужна собственная A/AAAA-запись и соответствующие `TURN_SERVER_URL_*`.

## 4. VPS и операционная система

Документированный контур проверяется на 64-bit Ubuntu 24.04 LTS. Docker также официально
поддерживает Ubuntu 22.04 LTS и актуальные версии, перечисленные в
[Docker Engine installation guide](https://docs.docker.com/engine/install/ubuntu/), но команды и
smoke-тест данного репозитория ориентированы на 24.04.

VPS должен иметь:

- статический публичный IPv4;
- SSH-доступ пользователя с `sudo`;
- x86_64/amd64 или arm64 CPU;
- синхронизацию времени через systemd-timesyncd/chrony;
- исходящий TCP `443` к registries, GitHub, ACME и APNs;
- возможность публиковать большой UDP relay range;
- файловую систему с поддержкой Docker volumes.

### Ресурсы

Следующие значения — эксплуатационные ориентиры, а не программные лимиты.

| Нагрузка | CPU | RAM | Диск | Назначение |
| --- | ---: | ---: | ---: | --- |
| Минимальный smoke/пилот | 2 vCPU | 4 ГБ | 30 ГБ SSD | ограниченное число пользователей |
| Начальный корпоративный контур | 4 vCPU | 8 ГБ | 80 ГБ SSD | рабочая установка с запасом для build и backup |
| Рост нагрузки | от 8 vCPU | от 16 ГБ | по retention | требует измерения DB, media и TURN traffic |

Во время первой Docker-сборки Rust требуется больше диска и памяти, чем работающему binary. На VPS
с 4 ГБ RAM рекомендуется иметь swap и не запускать параллельно другие тяжёлые builds. Размер диска
определяется главным образом ciphertext-вложениями, PostgreSQL retention и резервными копиями.

## 5. Сетевые требования

| Направление | Протокол/порт | Источник | Назначение |
| --- | --- | --- | --- |
| входящий | TCP `80` | интернет | ACME challenge и redirect на HTTPS |
| входящий | TCP `443` | устройства | API, WebSocket, TLS |
| входящий | UDP `3478` | устройства | STUN/TURN |
| входящий | TCP `3478` | устройства | TURN fallback |
| входящий, опционально | TCP `5349` | устройства | TURN over TLS при отдельной TLS-настройке coturn |
| входящий | UDP `49152–65535` | устройства/peers | TURN relay allocations |
| входящий | TCP `22` | административные IP | SSH |
| исходящий | TCP `443` | backend | APNs, registries, GitHub, ACME |

PostgreSQL `5432`, Redis `6379`, MinIO `9000/9001` и backend `3100` наружу не публикуются.

Docker предупреждает, что опубликованные container ports могут обходить правила UFW/firewalld.
Ограничения следует задавать одновременно в firewall облачного провайдера и, при необходимости, в
цепочке `DOCKER-USER`. См. раздел **Firewall limitations** в
[официальной инструкции Docker](https://docs.docker.com/engine/install/ubuntu/).

Если VPS находится за NAT, `TURN_EXTERNAL_IP` должен содержать публичный адрес, а
`TURN_PRIVATE_IP` — адрес интерфейса VPS. На VPS с публичным адресом непосредственно на интерфейсе
оба значения обычно совпадают.

## 6. Локальный контур

Для `compose.dev.yml` нужны:

- Git;
- Docker Desktop либо Docker Engine и Compose v2;
- 4 ГБ свободной RAM и около 10 ГБ диска;
- свободные TCP-порты `3100`, `5432`, `6379`, `9000`, `9001`.

Порты можно переопределить переменными `TELLME_HTTP_PORT`, `TELLME_POSTGRES_PORT`,
`TELLME_REDIS_PORT`, `TELLME_MINIO_PORT`, `TELLME_MINIO_CONSOLE_PORT`. При изменении HTTP-порта
нужно также изменить endpoint iOS local profile.

## 7. Что не требуется

Проект не требует SMTP-сервера, Kubernetes, внешнего Redis/PostgreSQL или платного S3. Эти
компоненты можно вынести в managed services позднее, но опубликованный Compose использует локальные
Docker volumes и MinIO. Для server-only smoke APNs можно временно отключить; для полноценной работы
фоновых уведомлений и входящих вызовов на физических устройствах APNs обязателен.
