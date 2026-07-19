# Настройка Apple Developer и iOS-клиента

## 1. Назначение

Проект нельзя выпустить под идентификаторами и signing team исходной сборки. Организация должна
создать собственные identifiers, включить capabilities, настроить endpoints и подписать оба
targets. Изменения выполняются до первого Archive.

Нужны активное членство Apple Developer Program, права Account Holder/Admin для создания key и
доступ к App Store Connect. Apple описывает зависимость capabilities от membership в
[Capabilities Overview](https://developer.apple.com/help/account/capabilities/capabilities-overview).

## 2. Выбрать идентификаторы

В примерах используется namespace `com.company.tellme`. Замените `company` на обратный DNS-домен
организации. После публикации Bundle ID менять нельзя без создания отдельного приложения.

```text
Основное приложение       com.company.tellme
Notification extension   com.company.tellme.NotificationService
App Group                 group.com.company.tellme
APNs alert topic          com.company.tellme
APNs VoIP topic           com.company.tellme.voip
```

## 3. Зарегистрировать identifiers

В [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):

1. Создайте explicit App ID `com.company.tellme`.
2. Включите **Push Notifications** и **App Groups**.
3. Создайте App Group `group.com.company.tellme` и назначьте основному App ID.
4. Создайте explicit App ID `com.company.tellme.NotificationService`.
5. Включите для extension **App Groups** и назначьте ту же группу.

Apple указывает, что после изменения capabilities существующие provisioning profiles могут стать
недействительными. Разрешите Xcode обновить automatic signing либо пересоздайте profiles. См.
[Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/).

## 4. Создать APNs authentication key

В **Certificates, Identifiers & Profiles → Keys**:

1. Нажмите `+` и задайте техническое имя key.
2. Включите **Apple Push Notification service (APNs)**.
3. Выберите подходящий Team Scoped или Topic Specific режим.
4. Подтвердите создание и скачайте `.p8`.
5. Зафиксируйте Key ID; Team ID доступен в membership details.
6. Сохраните `.p8` в secret storage организации.

Private key скачивается однократно. Не отправляйте его в messenger, email, issue, CI artifact или
Git. Backend использует token-based APNs authentication; один корректно настроенный key может
работать с development и production environments. Официальные сведения:
[APNs keys](https://developer.apple.com/help/account/keys/create-a-private-key) и
[token connection](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).

На VPS заполните:

```dotenv
APNS_ENABLED=true
APNS_BUNDLE_ID=com.company.tellme
APNS_VOIP_TOPIC=com.company.tellme.voip
APNS_PRODUCTION=true
APNS_KEY_ID=YYYYYYYYYY
APNS_TEAM_ID=XXXXXXXXXX
APNS_PRIVATE_KEY_PATH=/run/secrets/tellme/AuthKey.p8
```

Debug-сборка получает sandbox device tokens, Release/TestFlight — production tokens. Backend
сохраняет environment вместе с token и умеет повторить запрос в альтернативный APNs environment
при типичной ошибке несоответствия. Для production всё равно оставляйте `APNS_PRODUCTION=true`.

## 5. Настроить проект в Xcode

Откройте:

```bash
open messenger/messenger.xcodeproj
```

### Signing

Для targets `messenger` и `MessengerNotificationService`:

1. Откройте **Signing & Capabilities**.
2. Выберите Apple Developer Team организации.
3. Оставьте **Automatically manage signing**, если политика организации это допускает.
4. Убедитесь, что signing status не содержит ошибок.

### Build settings основного target

В target `messenger` откройте **Build Settings**, включите отображение **All** и измените значения
для Debug и Release:

| Setting | Значение |
| --- | --- |
| `TELLME_APP_BUNDLE_ID` | `com.company.tellme` |
| `TELLME_APP_GROUP_ID` | `group.com.company.tellme` |
| `TELLME_API_BASE_URL` | `https://chat.corp.example/api` |
| `TELLME_WS_BASE_URL` | `wss://chat.corp.example/socket.io` |
| `TELLME_TURN_URL` | `turn:chat.corp.example:3478` |
| `TELLME_STUN_URL` | `stun:chat.corp.example:3478` |
| `TELLME_API_PIN_HOST` | `chat.corp.example` |
| `TELLME_API_PRIMARY_CERT_SHA256` | пусто при system trust либо SHA-256 leaf certificate |
| `TELLME_API_BACKUP_CERT_SHA256` | пусто либо pin следующего certificate |

`PRODUCT_BUNDLE_IDENTIFIER`, Info.plist и entitlements ссылаются на эти settings. Не заменяйте
значения непосредственно в скомпилированном plist.

### Build settings extension

Для target `MessengerNotificationService` задайте:

| Setting | Значение |
| --- | --- |
| `TELLME_NOTIFICATION_BUNDLE_ID` | `com.company.tellme.NotificationService` |
| `TELLME_APP_GROUP_ID` | `group.com.company.tellme` |

### Имя приложения

Измените `CFBundleDisplayName` в двух файлах:

- `messenger/messenger/Info.plist`;
- `messenger/MessengerNotificationService/Info.plist`.

Проверьте AppIcon, LaunchScreen, purpose strings камеры/микрофона/фото и локализацию перед внешним
распространением. Purpose strings должны соответствовать фактической политике организации.

## 6. Certificate pinning

Пустые `TELLME_API_*_CERT_SHA256` означают стандартную системную проверку TLS без дополнительного
pinning. Это безопасный исходный режим при корректном публичном certificate chain.

Если организация включает leaf-certificate pinning, вычислите hash DER certificate:

```bash
openssl s_client -servername chat.corp.example -connect chat.corp.example:443 </dev/null 2>/dev/null \
  | openssl x509 -outform DER \
  | shasum -a 256
```

Задайте текущий hash как primary, а certificate следующей ротации — как backup. Автоматически
обновляемый ACME certificate без заранее подготовленного backup pin может заблокировать клиентам
доступ после renewal. Если процесс pin rotation не формализован, оставьте оба значения пустыми и
используйте system trust.

## 7. Проверить build settings без запуска

```bash
xcodebuild -project messenger/messenger.xcodeproj \
  -scheme messenger \
  -configuration Release \
  -showBuildSettings \
  | grep -E 'DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|TELLME_(API|WS|TURN|STUN|APP_)'
```

В выводе не должно быть identifiers или domain исходной сборки. Затем выполните Simulator tests:

```bash
xcodebuild test \
  -project messenger/messenger.xcodeproj \
  -scheme messenger \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -only-testing:messengerTests
```

## 8. Проверить на физическом устройстве

1. Выберите iPhone как destination и выполните Run.
2. Разрешите уведомления, микрофон и камеру.
3. Зарегистрируйте две отдельные тестовые учётные записи на двух устройствах.
4. Проверьте foreground/background получение сообщений.
5. Заблокируйте устройство и проверьте входящий вызов.
6. Выполните звонок между разными сетями и подтвердите TURN relay по server logs.

Simulator подходит для unit/UI tests, но не подтверждает production signing, APNs delivery,
PushKit/CallKit wakeup или поведение сети физического устройства.

## 9. Создать App Store Connect record

В App Store Connect создайте новое iOS-приложение:

- выберите основной Bundle ID;
- задайте уникальный SKU организации;
- заполните privacy, export compliance, beta review и contact information;
- добавьте internal TestFlight group;
- после обработки build добавьте external group.

Bundle ID и version из archive связывают upload с App Store Connect record. Apple перечисляет
поддерживаемые способы в [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds).

## 10. Archive и TestFlight

1. В Xcode выберите **Any iOS Device (arm64)**.
2. Выберите **Product → Archive**.
3. В Organizer выполните **Validate App**.
4. Устраните signing, entitlement и privacy errors.
5. Выполните **Distribute App → App Store Connect → Upload**.
6. Дождитесь состояния processed в App Store Connect.
7. Добавьте build во внутреннюю группу, затем во внешнюю.
8. Заполните **What to Test** и отправьте первый внешний build на TestFlight App Review.
9. После approval создайте или включите public link.

Apple допускает external testers только после добавления build во внешнюю группу; первый build
обычно проходит полную beta review. Подробности: [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/).

Открытая ссылка исходной beta:
[https://testflight.apple.com/join/qP7BxM1e](https://testflight.apple.com/join/qP7BxM1e). Для
собственного корпоративного App Store Connect record будет создана другая ссылка.

## 11. Типовые signing ошибки

| Ошибка | Проверка |
| --- | --- |
| App ID cannot be registered | Bundle ID уже занят или роль не позволяет регистрацию |
| Provisioning profile doesn't include App Group | App Group не назначен обоим identifiers; profile устарел |
| aps-environment missing | Push Notifications не включён или profile не обновлён |
| Embedded binary bundle identifier | extension ID не является дочерним к app ID |
| APNs `BadDeviceToken` | sandbox/production token отправлен в неверный environment |
| APNs `DeviceTokenNotForTopic` | `APNS_BUNDLE_ID` не совпадает с подписанным Bundle ID |
| Transport error после TLS renewal | устарел certificate pin; проверьте primary/backup settings |

APNs response codes приведены в
[официальном справочнике Apple](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).
