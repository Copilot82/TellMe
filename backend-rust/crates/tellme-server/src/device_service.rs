//! Service-level device registration, revocation, and push-token route contract.

use crate::auth::DeviceCertificate;
use crate::auth_service::{ApiError, AuthenticatedSession, StoreError};
use crate::devices::{
    effective_push_mode, effective_push_token_kind, revoke_signature_valid,
    validate_device_registration, DevicePublicKeys, PushMode, PushTokenKind,
};
use serde::{Deserialize, Serialize};

/// Account identity material needed to validate device certificates.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceAccountRecord {
    user_handle: String,
    account_sign_pub: String,
}

impl DeviceAccountRecord {
    #[must_use]
    pub const fn new(user_handle: String, account_sign_pub: String) -> Self {
        Self {
            user_handle,
            account_sign_pub,
        }
    }

    #[must_use]
    pub fn user_handle(&self) -> &str {
        &self.user_handle
    }

    #[must_use]
    pub fn account_sign_pub(&self) -> &str {
        &self.account_sign_pub
    }
}

/// Device row returned by register/revoke.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DeviceRouteRecord {
    pub device_id: String,
    pub dk_sign_pub: String,
    pub dk_dh_pub: String,
    pub state: String,
    pub device_certificate_chain: Vec<DeviceCertificate>,
}

/// Current authenticated device signing state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentDeviceRecord {
    sign_pub: String,
    active: bool,
}

impl CurrentDeviceRecord {
    #[must_use]
    pub const fn new(sign_pub: String, active: bool) -> Self {
        Self { sign_pub, active }
    }

    #[must_use]
    pub fn sign_pub(&self) -> &str {
        &self.sign_pub
    }

    #[must_use]
    pub const fn active(&self) -> bool {
        self.active
    }
}

/// Push token row as exposed by `/api/devices/push/tokens`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PushTokenRecord {
    pub id: String,
    pub user_id: String,
    pub device_type: String,
    pub token: String,
    pub device_name: Option<String>,
    pub os_version: Option<String>,
    pub app_version: Option<String>,
    pub push_enabled: bool,
    pub push_environment: String,
    pub push_mode: PushMode,
    pub token_kind: PushTokenKind,
    pub last_used_at: Option<String>,
    pub created_at: Option<String>,
}

/// Storage boundary for device routes.
// Store implementations only receive public device material, never private device keys.
pub trait DeviceStore {
    /// Finds account identity for device certificate validation.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_account_identity(
        &mut self,
        account_id: &str,
    ) -> Result<Option<DeviceAccountRecord>, StoreError>;

    /// Registers or reactivates a device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot upsert the device.
    fn register_device(
        &mut self,
        account_id: &str,
        device_keys: &DevicePublicKeys,
        certificate_chain: &[DeviceCertificate],
    ) -> Result<DeviceRouteRecord, StoreError>;

    /// Finds the current authenticated device signing key.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_current_device(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<CurrentDeviceRecord>, StoreError>;

    /// Revokes one device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the device.
    fn revoke_device(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<DeviceRouteRecord>, StoreError>;

    /// Upserts a push token.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot upsert the token.
    fn upsert_push_token(
        &mut self,
        account_id: &str,
        device_id: &str,
        input: &PushTokenUpsert,
    ) -> Result<PushTokenRecord, StoreError>;

    /// Lists account push tokens.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn list_push_tokens(&mut self, account_id: &str) -> Result<Vec<PushTokenRecord>, StoreError>;

    /// Updates push-enabled state.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the token.
    fn update_push_enabled(
        &mut self,
        account_id: &str,
        token: &str,
        push_enabled: bool,
    ) -> Result<Option<PushTokenRecord>, StoreError>;

    /// Updates push privacy mode.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the token.
    fn update_push_mode(
        &mut self,
        account_id: &str,
        token: &str,
        push_mode: PushMode,
    ) -> Result<Option<PushTokenRecord>, StoreError>;

    /// Updates APNs token surface.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the token.
    fn update_push_token_kind(
        &mut self,
        account_id: &str,
        token: &str,
        token_kind: PushTokenKind,
    ) -> Result<Option<PushTokenRecord>, StoreError>;

    /// Deletes a push token.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot delete the token.
    fn delete_push_token(&mut self, account_id: &str, token: &str) -> Result<bool, StoreError>;
}

/// Request body for `/api/devices/register`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct DeviceRegisterRequest {
    pub device_pub_keys: DevicePublicKeys,
    pub device_certificate_chain: Vec<DeviceCertificate>,
}

/// Request body for `/api/devices/revoke`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct DeviceRevokeRequest {
    pub device_id: String,
    pub signature: String,
    pub timestamp: Option<String>,
}

/// Request body for registering a push token.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PushTokenUpsert {
    pub device_type: String,
    pub token: String,
    pub device_name: Option<String>,
    pub os_version: Option<String>,
    pub app_version: Option<String>,
    pub push_enabled: Option<bool>,
    pub push_environment: Option<String>,
    pub push_mode: Option<String>,
    pub token_kind: Option<String>,
}

/// Request body for updating a push token.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PushTokenUpdate {
    pub push_enabled: Option<bool>,
    pub push_mode: Option<String>,
    pub token_kind: Option<String>,
}

/// Response body for push token list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PushTokenListResponse {
    pub tokens: Vec<PushTokenRecord>,
}

/// Service implementation for device routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceService;

impl DeviceService {
    /// Registers an additional account device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the account is missing, certificate chain is invalid, or storage fails.
    pub fn register<S: DeviceStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &DeviceRegisterRequest,
        now_ms: u64,
    ) -> Result<DeviceRouteRecord, ApiError> {
        let account = store
            .find_account_identity(&auth.account_id)
            .map_err(|_| ApiError::internal())?;
        let Some(account) = account else {
            return Err(ApiError::not_found("Account not found"));
        };
        validate_device_registration(&crate::devices::DeviceRegistrationInput {
            account_handle: account.user_handle(),
            account_sign_pub: account.account_sign_pub(),
            device_keys: &request.device_pub_keys,
            certificate_chain: &request.device_certificate_chain,
            now_ms,
        })
        .map_err(|_| ApiError::unauthorized("Invalid device certificate chain"))?;

        store
            .register_device(
                &auth.account_id,
                &request.device_pub_keys,
                &request.device_certificate_chain,
            )
            .map_err(|_| ApiError::internal())
    }

    /// Revokes a device after current-device signature verification.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when signature verification, device lookup, or storage update fails.
    pub fn revoke<S: DeviceStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &DeviceRevokeRequest,
    ) -> Result<DeviceRouteRecord, ApiError> {
        let current = store
            .find_current_device(&auth.account_id, &auth.device_id)
            .map_err(|_| ApiError::internal())?;
        let Some(current) = current.filter(CurrentDeviceRecord::active) else {
            return Err(ApiError::unauthorized("Invalid revoke signature"));
        };
        if !revoke_signature_valid(
            &request.device_id,
            request.timestamp.as_deref(),
            &request.signature,
            current.sign_pub(),
        ) {
            return Err(ApiError::unauthorized("Invalid revoke signature"));
        }
        let revoked = store
            .revoke_device(&auth.account_id, &request.device_id)
            .map_err(|_| ApiError::internal())?;
        revoked.ok_or_else(|| ApiError::not_found("Device not found"))
    }

    /// Registers or updates a push token for the authenticated device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the request is invalid or storage fails.
    pub fn upsert_push_token<S: DeviceStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &PushTokenUpsert,
    ) -> Result<PushTokenRecord, ApiError> {
        validate_push_token_upsert(request)?;
        store
            .upsert_push_token(&auth.account_id, &auth.device_id, request)
            .map_err(|_| ApiError::internal())
    }

    /// Lists account push tokens.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when storage lookup fails.
    pub fn list_push_tokens<S: DeviceStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
    ) -> Result<PushTokenListResponse, ApiError> {
        let tokens = store
            .list_push_tokens(&auth.account_id)
            .map_err(|_| ApiError::internal())?;
        Ok(PushTokenListResponse { tokens })
    }

    /// Updates one push token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when request validation, token lookup, or storage update fails.
    pub fn update_push_token<S: DeviceStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        token: &str,
        request: &PushTokenUpdate,
    ) -> Result<PushTokenRecord, ApiError> {
        validate_push_token_update(request)?;
        let enabled_result = match request.push_enabled {
            Some(enabled) => store
                .update_push_enabled(&auth.account_id, token, enabled)
                .map_err(|_| ApiError::internal())?,
            None => None,
        };
        let mode_result = match request.push_mode.as_deref() {
            Some(mode) => store
                .update_push_mode(&auth.account_id, token, effective_push_mode(Some(mode)))
                .map_err(|_| ApiError::internal())?,
            None => None,
        };
        let kind_result = match request.token_kind.as_deref() {
            Some(kind) => store
                .update_push_token_kind(
                    &auth.account_id,
                    token,
                    effective_push_token_kind(Some(kind)),
                )
                .map_err(|_| ApiError::internal())?,
            None => None,
        };

        kind_result
            .or(mode_result)
            .or(enabled_result)
            .ok_or_else(|| ApiError::not_found("Token not found"))
    }

    /// Deletes one push token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the token is missing or storage delete fails.
    pub fn delete_push_token<S: DeviceStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        token: &str,
    ) -> Result<(), ApiError> {
        let deleted = store
            .delete_push_token(&auth.account_id, token)
            .map_err(|_| ApiError::internal())?;
        if deleted {
            Ok(())
        } else {
            Err(ApiError::not_found("Token not found"))
        }
    }
}

pub(crate) fn validate_push_token_upsert(request: &PushTokenUpsert) -> Result<(), ApiError> {
    if !matches!(
        request.device_type.as_str(),
        "ios" | "macos" | "windows" | "android" | "web"
    ) || request.token.len() < 8
        || request.token.len() > 1_024
        || request
            .device_name
            .as_ref()
            .is_some_and(|value| value.len() > 255)
        || request
            .os_version
            .as_ref()
            .is_some_and(|value| value.len() > 128)
        || request
            .app_version
            .as_ref()
            .is_some_and(|value| value.len() > 128)
        || request
            .push_environment
            .as_ref()
            .is_some_and(|value| !matches!(value.as_str(), "sandbox" | "production"))
        || request
            .push_mode
            .as_ref()
            .is_some_and(|value| !matches!(value.as_str(), "privacy_first" | "fast_notify"))
        || request
            .token_kind
            .as_ref()
            .is_some_and(|value| !matches!(value.as_str(), "alert" | "voip"))
    {
        return Err(ApiError::bad_request("Invalid push token payload"));
    }

    Ok(())
}

pub(crate) fn validate_push_token_update(request: &PushTokenUpdate) -> Result<(), ApiError> {
    if request.push_enabled.is_none() && request.push_mode.is_none() && request.token_kind.is_none()
    {
        return Err(ApiError::bad_request("Invalid push token update"));
    }
    if request
        .push_mode
        .as_ref()
        .is_some_and(|value| !matches!(value.as_str(), "privacy_first" | "fast_notify"))
    {
        return Err(ApiError::bad_request("Invalid push token update"));
    }
    if request
        .token_kind
        .as_ref()
        .is_some_and(|value| !matches!(value.as_str(), "alert" | "voip"))
    {
        return Err(ApiError::bad_request("Invalid push token update"));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        CurrentDeviceRecord, DeviceAccountRecord, DeviceRegisterRequest, DeviceRevokeRequest,
        DeviceRouteRecord, DeviceService, DeviceStore, PushTokenRecord, PushTokenUpdate,
        PushTokenUpsert,
    };
    use crate::auth::{
        device_certificate_signing_payload, CertificateIssuerKind, DeviceCertificate,
    };
    use crate::auth_service::{ApiError, ApiStatus, AuthenticatedSession, StoreError};
    use crate::devices::{DevicePublicKeys, PushMode, PushTokenKind};
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine as _;
    use ed25519_dalek::{Signer, SigningKey};
    use std::collections::BTreeMap;

    const ACCOUNT_ID: &str = "acc-1";
    const HANDLE: &str = "@alice:example.com";
    const DEVICE_ID: &str = "ios-primary";
    const NEW_DEVICE_ID: &str = "ios-linked";
    const NOW_MS: u64 = 1_772_106_000_000;
    const NOW_ISO: &str = "2026-02-26T12:00:00.000Z";

    #[test]
    fn registers_device_after_certificate_validation() {
        let (account_key, account_pub) = signing_material(8);
        let (_device_key, device_pub) = signing_material(9);
        let request = register_request(&account_key, &account_pub, &device_pub);
        let mut store = FakeDeviceStore::with_identity(account_pub);

        let response = DeviceService::register(&mut store, &auth(), &request, NOW_MS);

        assert!(response.is_ok());
        let Ok(device) = response else {
            return;
        };
        assert_eq!(device.device_id, NEW_DEVICE_ID);
        assert_eq!(store.registered_devices.len(), 1);
    }

    #[test]
    fn rejects_register_for_missing_account_or_bad_chain() {
        let (account_key, account_pub) = signing_material(8);
        let (_device_key, device_pub) = signing_material(9);
        let request = register_request(&account_key, &account_pub, &device_pub);

        assert_eq!(
            DeviceService::register(&mut FakeDeviceStore::default(), &auth(), &request, NOW_MS)
                .err(),
            Some(ApiError::new(
                ApiStatus::NotFound,
                "Account not found",
                None
            ))
        );

        let mut bad_request = request;
        if let Some(certificate) = bad_request.device_certificate_chain.first_mut() {
            certificate.signature = "bad-signature".to_owned();
        }
        let mut store = FakeDeviceStore::with_identity(account_pub);
        assert_eq!(
            DeviceService::register(&mut store, &auth(), &bad_request, NOW_MS).err(),
            Some(ApiError::new(
                ApiStatus::Unauthorized,
                "Invalid device certificate chain",
                None
            ))
        );
    }

    #[test]
    fn revokes_device_with_current_device_signature() {
        let (current_key, current_pub) = signing_material(7);
        let mut store = FakeDeviceStore::with_current_device(current_pub);
        store.devices.insert(
            NEW_DEVICE_ID.to_owned(),
            device_route_record(NEW_DEVICE_ID, "revoked"),
        );
        let proof = crate::devices::revoke_proof(NEW_DEVICE_ID, Some(NOW_ISO));
        let request = DeviceRevokeRequest {
            device_id: NEW_DEVICE_ID.to_owned(),
            signature: sign(&current_key, &proof),
            timestamp: Some(NOW_ISO.to_owned()),
        };

        let response = DeviceService::revoke(&mut store, &auth(), &request);

        assert!(response.is_ok());
        assert_eq!(
            store.revoked_devices.first().map(String::as_str),
            Some(NEW_DEVICE_ID)
        );
    }

    #[test]
    fn rejects_revoke_with_invalid_signature() {
        let (_current_key, current_pub) = signing_material(7);
        let mut store = FakeDeviceStore::with_current_device(current_pub);
        let request = DeviceRevokeRequest {
            device_id: NEW_DEVICE_ID.to_owned(),
            signature: "bad-signature".to_owned(),
            timestamp: Some(NOW_ISO.to_owned()),
        };

        assert_eq!(
            DeviceService::revoke(&mut store, &auth(), &request).err(),
            Some(ApiError::new(
                ApiStatus::Unauthorized,
                "Invalid revoke signature",
                None
            ))
        );
    }

    #[test]
    fn upserts_push_token_with_defaults() {
        let mut store = FakeDeviceStore::default();
        let request = PushTokenUpsert {
            device_type: "ios".to_owned(),
            token: "apns-token".to_owned(),
            device_name: None,
            os_version: None,
            app_version: None,
            push_enabled: None,
            push_environment: None,
            push_mode: None,
            token_kind: None,
        };

        let response = DeviceService::upsert_push_token(&mut store, &auth(), &request);

        assert!(response.is_ok());
        let Ok(token) = response else {
            return;
        };
        assert!(token.push_enabled);
        assert_eq!(token.push_environment, "sandbox");
        assert_eq!(token.push_mode, PushMode::PrivacyFirst);
        assert_eq!(token.token_kind, PushTokenKind::Alert);
    }

    #[test]
    fn lists_updates_and_deletes_push_tokens() {
        let mut store = FakeDeviceStore::default();
        store
            .push_tokens
            .insert("apns-token".to_owned(), push_token_record());

        let listed = DeviceService::list_push_tokens(&mut store, &auth());
        assert_eq!(listed.as_ref().map(|body| body.tokens.len()), Ok(1));

        let updated = DeviceService::update_push_token(
            &mut store,
            &auth(),
            "apns-token",
            &PushTokenUpdate {
                push_enabled: Some(false),
                push_mode: Some("fast_notify".to_owned()),
                token_kind: Some("voip".to_owned()),
            },
        );
        assert!(updated.is_ok());
        let Ok(token) = updated else {
            return;
        };
        assert!(!token.push_enabled);
        assert_eq!(token.push_mode, PushMode::FastNotify);
        assert_eq!(token.token_kind, PushTokenKind::Voip);

        assert_eq!(
            DeviceService::delete_push_token(&mut store, &auth(), "apns-token"),
            Ok(())
        );
        assert_eq!(
            DeviceService::delete_push_token(&mut store, &auth(), "missing").err(),
            Some(ApiError::new(ApiStatus::NotFound, "Token not found", None))
        );
    }

    fn auth() -> AuthenticatedSession {
        AuthenticatedSession {
            account_id: ACCOUNT_ID.to_owned(),
            user_handle: HANDLE.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            session_id: "sess-1".to_owned(),
        }
    }

    fn register_request(
        account_key: &SigningKey,
        _account_pub: &str,
        device_pub: &str,
    ) -> DeviceRegisterRequest {
        let mut certificate = DeviceCertificate {
            device_certificate_version: 2,
            account_handle: HANDLE.to_owned(),
            device_id: NEW_DEVICE_ID.to_owned(),
            device_sign_pub: device_pub.to_owned(),
            device_dh_pub: "new-dh".to_owned(),
            issuer_kind: CertificateIssuerKind::Account,
            issuer_device_id: None,
            parent_certificate_id: None,
            issued_at: NOW_ISO.to_owned(),
            expires_at: None,
            signature: String::new(),
        };
        certificate.signature = sign(
            account_key,
            &device_certificate_signing_payload(&certificate),
        );

        DeviceRegisterRequest {
            device_pub_keys: DevicePublicKeys::new(
                NEW_DEVICE_ID.to_owned(),
                device_pub.to_owned(),
                "new-dh".to_owned(),
            ),
            device_certificate_chain: vec![certificate],
        }
    }

    fn device_route_record(device_id: &str, state: &str) -> DeviceRouteRecord {
        DeviceRouteRecord {
            device_id: device_id.to_owned(),
            dk_sign_pub: "dk-sign".to_owned(),
            dk_dh_pub: "dk-dh".to_owned(),
            state: state.to_owned(),
            device_certificate_chain: Vec::new(),
        }
    }

    fn push_token_record() -> PushTokenRecord {
        PushTokenRecord {
            id: "token-row-1".to_owned(),
            user_id: ACCOUNT_ID.to_owned(),
            device_type: "ios".to_owned(),
            token: "apns-token".to_owned(),
            device_name: None,
            os_version: None,
            app_version: None,
            push_enabled: true,
            push_environment: "sandbox".to_owned(),
            push_mode: PushMode::PrivacyFirst,
            token_kind: PushTokenKind::Alert,
            last_used_at: None,
            created_at: None,
        }
    }

    fn signing_material(seed: u8) -> (SigningKey, String) {
        let signing_key = SigningKey::from_bytes(&[seed; 32]);
        let public_key = STANDARD.encode(signing_key.verifying_key().to_bytes());
        (signing_key, public_key)
    }

    fn sign(signing_key: &SigningKey, message: &str) -> String {
        STANDARD.encode(signing_key.sign(message.as_bytes()).to_bytes())
    }

    #[derive(Debug, Clone, Default)]
    struct FakeDeviceStore {
        account: Option<DeviceAccountRecord>,
        current_device: Option<CurrentDeviceRecord>,
        devices: BTreeMap<String, DeviceRouteRecord>,
        registered_devices: Vec<String>,
        revoked_devices: Vec<String>,
        push_tokens: BTreeMap<String, PushTokenRecord>,
    }

    impl FakeDeviceStore {
        fn with_identity(account_pub: String) -> Self {
            Self {
                account: Some(DeviceAccountRecord::new(HANDLE.to_owned(), account_pub)),
                current_device: None,
                devices: BTreeMap::new(),
                registered_devices: Vec::new(),
                revoked_devices: Vec::new(),
                push_tokens: BTreeMap::new(),
            }
        }

        fn with_current_device(current_pub: String) -> Self {
            Self {
                account: None,
                current_device: Some(CurrentDeviceRecord::new(current_pub, true)),
                devices: BTreeMap::new(),
                registered_devices: Vec::new(),
                revoked_devices: Vec::new(),
                push_tokens: BTreeMap::new(),
            }
        }
    }

    impl DeviceStore for FakeDeviceStore {
        fn find_account_identity(
            &mut self,
            _account_id: &str,
        ) -> Result<Option<DeviceAccountRecord>, StoreError> {
            Ok(self.account.clone())
        }

        fn register_device(
            &mut self,
            _account_id: &str,
            device_keys: &DevicePublicKeys,
            certificate_chain: &[DeviceCertificate],
        ) -> Result<DeviceRouteRecord, StoreError> {
            self.registered_devices
                .push(device_keys.device_id().to_owned());
            let record = DeviceRouteRecord {
                device_id: device_keys.device_id().to_owned(),
                dk_sign_pub: device_keys.dk_sign_pub().to_owned(),
                dk_dh_pub: device_keys.dk_dh_pub().to_owned(),
                state: "active".to_owned(),
                device_certificate_chain: certificate_chain.to_vec(),
            };
            self.devices
                .insert(device_keys.device_id().to_owned(), record.clone());
            Ok(record)
        }

        fn find_current_device(
            &mut self,
            _account_id: &str,
            _device_id: &str,
        ) -> Result<Option<CurrentDeviceRecord>, StoreError> {
            Ok(self.current_device.clone())
        }

        fn revoke_device(
            &mut self,
            _account_id: &str,
            device_id: &str,
        ) -> Result<Option<DeviceRouteRecord>, StoreError> {
            self.revoked_devices.push(device_id.to_owned());
            Ok(self.devices.get(device_id).cloned())
        }

        fn upsert_push_token(
            &mut self,
            account_id: &str,
            _device_id: &str,
            input: &PushTokenUpsert,
        ) -> Result<PushTokenRecord, StoreError> {
            let record = PushTokenRecord {
                id: "token-row-1".to_owned(),
                user_id: account_id.to_owned(),
                device_type: input.device_type.clone(),
                token: input.token.clone(),
                device_name: input.device_name.clone(),
                os_version: input.os_version.clone(),
                app_version: input.app_version.clone(),
                push_enabled: input.push_enabled.unwrap_or(true),
                push_environment: input
                    .push_environment
                    .clone()
                    .unwrap_or_else(|| "sandbox".to_owned()),
                push_mode: crate::devices::effective_push_mode(input.push_mode.as_deref()),
                token_kind: crate::devices::effective_push_token_kind(input.token_kind.as_deref()),
                last_used_at: None,
                created_at: None,
            };
            self.push_tokens.insert(input.token.clone(), record.clone());
            Ok(record)
        }

        fn list_push_tokens(
            &mut self,
            _account_id: &str,
        ) -> Result<Vec<PushTokenRecord>, StoreError> {
            Ok(self.push_tokens.values().cloned().collect())
        }

        fn update_push_enabled(
            &mut self,
            _account_id: &str,
            token: &str,
            push_enabled: bool,
        ) -> Result<Option<PushTokenRecord>, StoreError> {
            let Some(record) = self.push_tokens.get_mut(token) else {
                return Ok(None);
            };
            record.push_enabled = push_enabled;
            Ok(Some(record.clone()))
        }

        fn update_push_mode(
            &mut self,
            _account_id: &str,
            token: &str,
            push_mode: PushMode,
        ) -> Result<Option<PushTokenRecord>, StoreError> {
            let Some(record) = self.push_tokens.get_mut(token) else {
                return Ok(None);
            };
            record.push_mode = push_mode;
            Ok(Some(record.clone()))
        }

        fn update_push_token_kind(
            &mut self,
            _account_id: &str,
            token: &str,
            token_kind: PushTokenKind,
        ) -> Result<Option<PushTokenRecord>, StoreError> {
            let Some(record) = self.push_tokens.get_mut(token) else {
                return Ok(None);
            };
            record.token_kind = token_kind;
            Ok(Some(record.clone()))
        }

        fn delete_push_token(
            &mut self,
            _account_id: &str,
            token: &str,
        ) -> Result<bool, StoreError> {
            Ok(self.push_tokens.remove(token).is_some())
        }
    }
}
