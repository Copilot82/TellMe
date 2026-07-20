# Apple Developer and iOS client setup

## 1. Purpose

The project cannot be distributed under the identifiers or signing team used by the original
build. The organization must create its own identifiers, enable capabilities, configure endpoints,
and sign both targets before the first Archive.

You need an active Apple Developer Program membership, Account Holder or Admin privileges to create
a key, and App Store Connect access. Apple documents membership-dependent features in
[Capabilities Overview](https://developer.apple.com/help/account/capabilities/capabilities-overview).

## 2. Select identifiers

The examples use the `com.company.tellme` namespace. Replace `company` with the organization's
reverse-DNS domain. Changing a Bundle ID after publication requires a separate application.

```text
Main application         com.company.tellme
Notification extension  com.company.tellme.NotificationService
App Group               group.com.company.tellme
APNs alert topic         com.company.tellme
APNs VoIP topic          com.company.tellme.voip
```

## 3. Register identifiers

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):

1. Create the explicit App ID `com.company.tellme`.
2. Enable **Push Notifications** and **App Groups**.
3. Create `group.com.company.tellme` and assign it to the main App ID.
4. Create the explicit App ID `com.company.tellme.NotificationService`.
5. Enable **App Groups** for the extension and assign the same group.

Apple notes that changing capabilities can invalidate existing provisioning profiles. Allow Xcode
to update automatic signing or recreate the profiles. See
[Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/).

## 4. Create an APNs authentication key

Under **Certificates, Identifiers & Profiles → Keys**:

1. Select `+` and enter a technical key name.
2. Enable **Apple Push Notification service (APNs)**.
3. Select the appropriate Team Scoped or Topic Specific mode.
4. Confirm creation and download the `.p8` file.
5. Record the Key ID; the Team ID is available in membership details.
6. Store the `.p8` file in organizational secret storage.

The private key can be downloaded only once. Never send it through a messenger, email, issue, CI
artifact, or Git. The backend uses token-based APNs authentication; one correctly configured key
can serve development and production environments. See Apple's
[APNs key instructions](https://developer.apple.com/help/account/keys/create-a-private-key) and
[token-connection documentation](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).

Configure the VPS:

```dotenv
APNS_ENABLED=true
APNS_BUNDLE_ID=com.company.tellme
APNS_VOIP_TOPIC=com.company.tellme.voip
APNS_PRODUCTION=true
APNS_KEY_ID=YYYYYYYYYY
APNS_TEAM_ID=XXXXXXXXXX
APNS_PRIVATE_KEY_PATH=/run/secrets/tellme/AuthKey.p8
```

A Debug build receives sandbox device tokens; Release and TestFlight builds receive production
tokens. The backend stores each token's environment and can retry against the alternate APNs
environment after a typical mismatch error. Keep `APNS_PRODUCTION=true` in production.

## 5. Configure the Xcode project

Open:

```bash
open messenger/messenger.xcodeproj
```

### Signing

For the `messenger` and `MessengerNotificationService` targets:

1. Open **Signing & Capabilities**.
2. Select the organization's Apple Developer Team.
3. Keep **Automatically manage signing** when organizational policy permits it.
4. Confirm that signing status has no errors.

### Main-target build settings

For target `messenger`, open **Build Settings**, select **All**, and set these Debug and Release
values:

| Setting | Value |
| --- | --- |
| `TELLME_APP_BUNDLE_ID` | `com.company.tellme` |
| `TELLME_APP_GROUP_ID` | `group.com.company.tellme` |
| `TELLME_API_BASE_URL` | `https://chat.corp.example/api` |
| `TELLME_WS_BASE_URL` | `wss://chat.corp.example/socket.io` |
| `TELLME_TURN_URL` | `turn:chat.corp.example:3478` |
| `TELLME_STUN_URL` | `stun:chat.corp.example:3478` |
| `TELLME_API_PIN_HOST` | `chat.corp.example` |
| `TELLME_API_PRIMARY_CERT_SHA256` | empty for system trust, or the leaf certificate SHA-256 |
| `TELLME_API_BACKUP_CERT_SHA256` | empty, or the next certificate pin |

`PRODUCT_BUNDLE_IDENTIFIER`, Info.plist, and entitlements reference these settings. Do not replace
values directly in the compiled plist.

### Extension build settings

For `MessengerNotificationService`, set:

| Setting | Value |
| --- | --- |
| `TELLME_NOTIFICATION_BUNDLE_ID` | `com.company.tellme.NotificationService` |
| `TELLME_APP_GROUP_ID` | `group.com.company.tellme` |

### Application name

Change `CFBundleDisplayName` in both files:

- `messenger/messenger/Info.plist`;
- `messenger/MessengerNotificationService/Info.plist`.

Before external distribution, verify AppIcon, LaunchScreen, camera, microphone, and photo purpose
strings, and localization. Purpose strings must match the organization's actual policy.

## 6. Certificate pinning

Empty `TELLME_API_*_CERT_SHA256` values select standard system TLS validation without additional
pinning. With a valid public certificate chain, this is a secure baseline.

If the organization enables leaf-certificate pinning, calculate the DER certificate hash:

```bash
openssl s_client -servername chat.corp.example -connect chat.corp.example:443 </dev/null 2>/dev/null \
  | openssl x509 -outform DER \
  | shasum -a 256
```

Use the current hash as primary and the next rotation certificate as backup. An automatically
renewed ACME certificate without a pre-provisioned backup pin can lock clients out after renewal.
If pin rotation is not formalized, leave both values empty and use system trust.

## 7. Inspect build settings without running

```bash
xcodebuild -project messenger/messenger.xcodeproj \
  -scheme messenger \
  -configuration Release \
  -showBuildSettings \
  | grep -E 'DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|TELLME_(API|WS|TURN|STUN|APP_)'
```

The output must not contain identifiers or domains from another deployment. Then run Simulator
tests:

```bash
xcodebuild test \
  -project messenger/messenger.xcodeproj \
  -scheme messenger \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -only-testing:messengerTests
```

## 8. Validate on physical devices

1. Select an iPhone as the destination and run the app.
2. Grant notification, microphone, and camera permissions.
3. Register two separate test accounts on two devices.
4. Verify foreground and background message delivery.
5. Lock one device and verify an incoming call.
6. Place a call across different networks and confirm TURN relay use in server logs.

Simulator is suitable for unit and UI tests but does not validate production signing, APNs
delivery, PushKit and CallKit wakeup, or physical-device network behavior.

## 9. Create an App Store Connect record

Create a new iOS application in App Store Connect:

- select the main Bundle ID;
- set a unique organizational SKU;
- complete privacy, export compliance, beta review, and contact information;
- add an internal TestFlight group;
- add an external group after the build is processed.

Bundle ID and version in the archive associate the upload with the App Store Connect record. Apple
documents supported methods under [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds).

## 10. Archive and TestFlight

1. In Xcode, select **Any iOS Device (arm64)**.
2. Select **Product → Archive**.
3. In Organizer, run **Validate App**.
4. Resolve signing, entitlement, and privacy errors.
5. Select **Distribute App → App Store Connect → Upload**.
6. Wait until processing completes in App Store Connect.
7. Add the build to the internal group, then the external group.
8. Complete **What to Test** and submit the first external build for TestFlight App Review.
9. After approval, create or enable the public link.

External testers can access only a build assigned to an external group; the first build normally
undergoes full beta review. See [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/).

Public link for the provided beta:
[https://testflight.apple.com/join/qP7BxM1e](https://testflight.apple.com/join/qP7BxM1e). A separate
corporate App Store Connect record receives its own link.

## 11. Common signing errors

| Error | Check |
| --- | --- |
| App ID cannot be registered | Bundle ID is already assigned or the role cannot register it |
| Provisioning profile doesn't include App Group | App Group is not assigned to both identifiers, or the profile is stale |
| aps-environment missing | Push Notifications is disabled or the profile was not refreshed |
| Embedded binary bundle identifier | extension ID is not a child of the app ID |
| APNs `BadDeviceToken` | sandbox or production token was sent to the wrong environment |
| APNs `DeviceTokenNotForTopic` | `APNS_BUNDLE_ID` differs from the signed Bundle ID |
| Transport error after TLS renewal | certificate pin is stale; inspect primary and backup settings |

See Apple's [APNs response reference](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).
