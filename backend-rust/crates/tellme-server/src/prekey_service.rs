//! Service-level prekey route contract.
//!
//! This keeps iOS-visible prekey behavior independent from the eventual `Postgres` repository implementation.

use crate::auth::{normalize_handle, DeviceCertificate};
use crate::auth_service::{ApiError, AuthenticatedSession, StoreError};
use crate::devices::PushMode;
use crate::prekeys::{
    build_prekey_bundle, bundle_push_mode, normalize_prekey_user_query, one_time_for_bundle,
    validate_publish_request, OneTimePrekey, PrekeyBundle, PrekeyBundleInput, PrekeyError,
    PrekeyPublishRequest, SignedPrekey,
};
use serde::Serialize;

/// Account row needed for prekey lookup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrekeyAccountRecord {
    id: String,
    user_handle: String,
    account_sign_pub: String,
    allow_search: bool,
}

impl PrekeyAccountRecord {
    #[must_use]
    pub const fn new(
        id: String,
        user_handle: String,
        account_sign_pub: String,
        allow_search: bool,
    ) -> Self {
        Self {
            id,
            user_handle,
            account_sign_pub,
            allow_search,
        }
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn user_handle(&self) -> &str {
        &self.user_handle
    }

    #[must_use]
    pub fn account_sign_pub(&self) -> &str {
        &self.account_sign_pub
    }

    #[must_use]
    pub const fn allow_search(&self) -> bool {
        self.allow_search
    }
}

/// Active-device row needed for prekey bundle construction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrekeyDeviceRecord {
    id: String,
    sign_pub: String,
    dh_pub: String,
    certificate_chain: Vec<DeviceCertificate>,
}

impl PrekeyDeviceRecord {
    #[must_use]
    pub const fn new(
        device_id: String,
        device_sign_pub: String,
        device_dh_pub: String,
        device_certificate_chain: Vec<DeviceCertificate>,
    ) -> Self {
        Self {
            id: device_id,
            sign_pub: device_sign_pub,
            dh_pub: device_dh_pub,
            certificate_chain: device_certificate_chain,
        }
    }

    #[must_use]
    pub fn device_id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn device_sign_pub(&self) -> &str {
        &self.sign_pub
    }

    #[must_use]
    pub fn device_dh_pub(&self) -> &str {
        &self.dh_pub
    }

    #[must_use]
    pub fn device_certificate_chain(&self) -> &[DeviceCertificate] {
        &self.certificate_chain
    }
}

/// Result from the transactional prekey publish operation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PublishedPrekeys {
    pub signed_prekey_id: String,
    pub one_time_prekeys_added: usize,
}

/// Storage boundary for prekey route behavior.
// Prekey lookup returns public bundles only; clients keep one-time private material locally.
pub trait PrekeyStore {
    /// Finds an account by normalized handle.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_account_by_handle(
        &mut self,
        user_handle: &str,
    ) -> Result<Option<PrekeyAccountRecord>, StoreError>;

    /// Finds an account by id.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_account_by_id(
        &mut self,
        account_id: &str,
    ) -> Result<Option<PrekeyAccountRecord>, StoreError>;

    /// Finds one active device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_active_device(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<PrekeyDeviceRecord>, StoreError>;

    /// Lists active devices for an account.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn list_active_devices(
        &mut self,
        account_id: &str,
    ) -> Result<Vec<PrekeyDeviceRecord>, StoreError>;

    /// Publishes signed and one-time prekeys transactionally.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot publish prekeys.
    fn publish_prekeys(
        &mut self,
        account_id: &str,
        device_id: &str,
        signed_prekey: &SignedPrekey,
        one_time_prekeys: &[OneTimePrekey],
    ) -> Result<PublishedPrekeys, StoreError>;

    /// Fetches the current signed prekey for a device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn get_signed_prekey(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<SignedPrekey>, StoreError>;

    /// Consumes one available one-time prekey for a device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot consume a prekey.
    fn consume_one_time_prekey(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<OneTimePrekey>, StoreError>;

    /// Lists enabled push privacy modes for a device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn enabled_push_modes(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Vec<PushMode>, StoreError>;
}

/// Query for `/api/prekeys/get`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrekeyLookupRequest {
    pub user: Option<String>,
    pub device_id: Option<String>,
    pub peek: bool,
}

/// Query for `/api/prekeys/self`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelfPrekeyRequest {
    pub device_id: Option<String>,
    pub peek: bool,
}

/// Response body for prekey bundle routes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PrekeyBundlesResponse {
    pub bundles: Vec<PrekeyBundle>,
}

/// Service implementation for prekey routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrekeyService;

impl PrekeyService {
    /// Publishes prekeys for the authenticated device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when request validation, active-device lookup, or storage publish fails.
    pub fn publish<S: PrekeyStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &PrekeyPublishRequest,
    ) -> Result<PublishedPrekeys, ApiError> {
        if let Err(error) = validate_publish_request(request, &auth.device_id, true) {
            return Err(publish_validation_error(&error));
        }

        let device = store
            .find_active_device(&auth.account_id, &auth.device_id)
            .map_err(|_| ApiError::internal())?;
        if device.is_none() {
            return Err(ApiError::not_found("Device not found"));
        }

        store
            .publish_prekeys(
                &auth.account_id,
                &auth.device_id,
                &request.signed_prekey,
                &request.one_time_prekeys,
            )
            .map_err(|_| ApiError::internal())
    }

    /// Returns public prekey bundles for a normalized handle.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for missing user query, unavailable users, hidden users, or storage failures.
    pub fn lookup<S: PrekeyStore>(
        store: &mut S,
        request: &PrekeyLookupRequest,
    ) -> Result<PrekeyBundlesResponse, ApiError> {
        let Some(user_handle) = normalize_prekey_user_query(request.user.as_deref()) else {
            return Err(ApiError::bad_request("user is required"));
        };
        let account = store
            .find_account_by_handle(&user_handle)
            .map_err(|_| ApiError::internal())?;
        let Some(account) = account.filter(PrekeyAccountRecord::allow_search) else {
            return Err(ApiError::not_found("Unavailable"));
        };

        build_bundles(store, &account, request.device_id.as_deref(), request.peek)
    }

    /// Returns prekey bundles for the authenticated account.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the authenticated account no longer exists or storage fails.
    pub fn lookup_self<S: PrekeyStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &SelfPrekeyRequest,
    ) -> Result<PrekeyBundlesResponse, ApiError> {
        let account = store
            .find_account_by_id(&auth.account_id)
            .map_err(|_| ApiError::internal())?;
        let Some(account) = account else {
            return Err(ApiError::not_found("Account not found"));
        };

        build_bundles(store, &account, request.device_id.as_deref(), request.peek)
    }
}

const fn publish_validation_error(error: &PrekeyError) -> ApiError {
    match error {
        PrekeyError::DeviceMismatch => {
            ApiError::forbidden("Can only publish prekeys for current device")
        }
        PrekeyError::DeviceNotActive => ApiError::not_found("Device not found"),
        PrekeyError::UnsupportedProtocolVersion
        | PrekeyError::InvalidSignedPrekey
        | PrekeyError::InvalidOneTimePrekey => ApiError::bad_request("Invalid prekey payload"),
    }
}

fn build_bundles<S: PrekeyStore>(
    store: &mut S,
    account: &PrekeyAccountRecord,
    target_device_id: Option<&str>,
    peek: bool,
) -> Result<PrekeyBundlesResponse, ApiError> {
    let devices = store
        .list_active_devices(account.id())
        .map_err(|_| ApiError::internal())?;
    let mut bundles = Vec::new();
    for device in devices {
        if target_device_id.is_some_and(|target| target != device.device_id()) {
            continue;
        }
        if let Some(bundle) = bundle_for_device(store, account, &device, peek)? {
            bundles.push(bundle);
        }
    }

    Ok(PrekeyBundlesResponse { bundles })
}

fn bundle_for_device<S: PrekeyStore>(
    store: &mut S,
    account: &PrekeyAccountRecord,
    device: &PrekeyDeviceRecord,
    peek: bool,
) -> Result<Option<PrekeyBundle>, ApiError> {
    let signed_prekey = store
        .get_signed_prekey(account.id(), device.device_id())
        .map_err(|_| ApiError::internal())?;
    let one_time = if peek {
        None
    } else {
        store
            .consume_one_time_prekey(account.id(), device.device_id())
            .map_err(|_| ApiError::internal())?
    };
    let modes = store
        .enabled_push_modes(account.id(), device.device_id())
        .map_err(|_| ApiError::internal())?;
    let one_time_prekey = one_time_for_bundle(peek, one_time);
    let input = PrekeyBundleInput {
        user_handle: account.user_handle(),
        account_sign_pub: account.account_sign_pub(),
        device_id: device.device_id(),
        device_sign_pub: device.device_sign_pub(),
        device_dh_pub: device.device_dh_pub(),
        device_certificate_chain: device.device_certificate_chain(),
        signed_prekey: signed_prekey.as_ref(),
        one_time_prekey: one_time_prekey.as_ref(),
        push_mode: bundle_push_mode(&modes),
    };

    Ok(build_prekey_bundle(&input))
}

#[must_use]
pub fn normalize_public_lookup_user(value: Option<&str>) -> Option<String> {
    normalize_prekey_user_query(value).map(|handle| normalize_handle(&handle))
}

#[cfg(test)]
mod tests {
    use super::{
        PrekeyAccountRecord, PrekeyBundlesResponse, PrekeyDeviceRecord, PrekeyLookupRequest,
        PrekeyService, PrekeyStore, PublishedPrekeys, SelfPrekeyRequest,
    };
    use crate::auth_service::{ApiError, ApiStatus, AuthenticatedSession, StoreError};
    use crate::devices::PushMode;
    use crate::prekeys::{OneTimePrekey, PrekeyPublishRequest, SignedPrekey};
    use std::collections::BTreeSet;

    const ACCOUNT_ID: &str = "acc-1";
    const HANDLE: &str = "@alice:example.com";
    const DEVICE_ID: &str = "ios-primary";

    #[test]
    fn publish_accepts_current_active_device() {
        let mut store = FakePrekeyStore::with_account_and_device();
        let request = publish_request(DEVICE_ID);

        let response = PrekeyService::publish(&mut store, &auth(), &request);

        assert_eq!(
            response,
            Ok(PublishedPrekeys {
                signed_prekey_id: "signed-1".to_owned(),
                one_time_prekeys_added: 1,
            })
        );
        assert_eq!(
            store.published.first().map(PublishedRequest::device_id),
            Some(DEVICE_ID)
        );
    }

    #[test]
    fn publish_rejects_other_device_before_storage_write() {
        let mut store = FakePrekeyStore::with_account_and_device();
        let request = publish_request("other-device");

        let response = PrekeyService::publish(&mut store, &auth(), &request);

        assert_eq!(
            response.err(),
            Some(ApiError::new(
                ApiStatus::Forbidden,
                "Can only publish prekeys for current device",
                None
            ))
        );
        assert!(store.published.is_empty());
    }

    #[test]
    fn public_lookup_hides_missing_and_unsearchable_accounts() {
        let mut missing_store = FakePrekeyStore::default();
        let request = PrekeyLookupRequest {
            user: Some(HANDLE.to_owned()),
            device_id: None,
            peek: true,
        };
        assert_eq!(
            PrekeyService::lookup(&mut missing_store, &request).err(),
            Some(ApiError::new(ApiStatus::NotFound, "Unavailable", None))
        );

        let mut hidden_store = FakePrekeyStore::with_account_and_device();
        if let Some(account) = hidden_store.accounts.first_mut() {
            account.allow_search = false;
        }
        assert_eq!(
            PrekeyService::lookup(&mut hidden_store, &request).err(),
            Some(ApiError::new(ApiStatus::NotFound, "Unavailable", None))
        );
    }

    #[test]
    fn lookup_builds_bundles_and_consumes_one_time_prekey_when_not_peeking() {
        let mut store = FakePrekeyStore::with_account_and_device();
        store.signed_prekeys.push(StoredSignedPrekey {
            account_id: ACCOUNT_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            signed_prekey: signed_prekey(),
        });
        store.one_time_prekeys.push(StoredOneTimePrekey {
            account_id: ACCOUNT_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            one_time_prekey: one_time_prekey(),
            consumed: false,
        });
        store.push_modes.push(StoredPushMode {
            account_id: ACCOUNT_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            mode: PushMode::FastNotify,
        });
        let request = PrekeyLookupRequest {
            user: Some(" @Alice:Example.COM ".to_owned()),
            device_id: Some(DEVICE_ID.to_owned()),
            peek: false,
        };

        let response = PrekeyService::lookup(&mut store, &request);

        assert_bundle_response(response, true, PushMode::FastNotify);
        assert_eq!(
            store.consumed_one_time_ids.first().map(String::as_str),
            Some("otp-1")
        );
    }

    #[test]
    fn self_lookup_requires_existing_account_and_skips_one_time_when_peeking() {
        let mut store = FakePrekeyStore::with_account_and_device();
        store.signed_prekeys.push(StoredSignedPrekey {
            account_id: ACCOUNT_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            signed_prekey: signed_prekey(),
        });
        store.one_time_prekeys.push(StoredOneTimePrekey {
            account_id: ACCOUNT_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            one_time_prekey: one_time_prekey(),
            consumed: false,
        });
        let request = SelfPrekeyRequest {
            device_id: Some(DEVICE_ID.to_owned()),
            peek: true,
        };

        let response = PrekeyService::lookup_self(&mut store, &auth(), &request);

        assert_bundle_response(response, false, PushMode::PrivacyFirst);
        assert!(store.consumed_one_time_ids.is_empty());

        let mut empty_store = FakePrekeyStore::default();
        assert_eq!(
            PrekeyService::lookup_self(&mut empty_store, &auth(), &request).err(),
            Some(ApiError::new(
                ApiStatus::NotFound,
                "Account not found",
                None
            ))
        );
    }

    fn assert_bundle_response(
        response: Result<PrekeyBundlesResponse, ApiError>,
        has_one_time: bool,
        push_mode: PushMode,
    ) {
        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.bundles.len(), 1);
        let Some(bundle) = body.bundles.first() else {
            return;
        };
        assert_eq!(bundle.user_handle, HANDLE);
        assert_eq!(bundle.device_id, DEVICE_ID);
        assert_eq!(bundle.signed_prekey.prekey_id, "signed-1");
        assert_eq!(bundle.one_time_prekey.is_some(), has_one_time);
        assert_eq!(bundle.push_mode, push_mode);
    }

    fn auth() -> AuthenticatedSession {
        AuthenticatedSession {
            account_id: ACCOUNT_ID.to_owned(),
            user_handle: HANDLE.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            session_id: "sess-1".to_owned(),
        }
    }

    fn publish_request(device_id: &str) -> PrekeyPublishRequest {
        PrekeyPublishRequest {
            protocol_version: Some(2),
            device_id: device_id.to_owned(),
            signed_prekey: signed_prekey(),
            one_time_prekeys: vec![one_time_prekey()],
        }
    }

    fn signed_prekey() -> SignedPrekey {
        SignedPrekey {
            prekey_id: "signed-1".to_owned(),
            signed_prekey_pub: "signed-pub".to_owned(),
            signature: "signed-signature".to_owned(),
            expires_at: None,
        }
    }

    fn one_time_prekey() -> OneTimePrekey {
        OneTimePrekey {
            prekey_id: "otp-1".to_owned(),
            prekey_pub: "otp-pub".to_owned(),
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakePrekeyStore {
        accounts: Vec<PrekeyAccountRecord>,
        devices: Vec<PrekeyDeviceRecord>,
        signed_prekeys: Vec<StoredSignedPrekey>,
        one_time_prekeys: Vec<StoredOneTimePrekey>,
        push_modes: Vec<StoredPushMode>,
        published: Vec<PublishedRequest>,
        consumed_one_time_ids: Vec<String>,
        duplicate_one_time_ids: BTreeSet<String>,
    }

    impl FakePrekeyStore {
        fn with_account_and_device() -> Self {
            Self {
                accounts: vec![PrekeyAccountRecord::new(
                    ACCOUNT_ID.to_owned(),
                    HANDLE.to_owned(),
                    "ik-sign".to_owned(),
                    true,
                )],
                devices: vec![PrekeyDeviceRecord::new(
                    DEVICE_ID.to_owned(),
                    "dk-sign".to_owned(),
                    "dk-dh".to_owned(),
                    Vec::new(),
                )],
                signed_prekeys: Vec::new(),
                one_time_prekeys: Vec::new(),
                push_modes: Vec::new(),
                published: Vec::new(),
                consumed_one_time_ids: Vec::new(),
                duplicate_one_time_ids: BTreeSet::new(),
            }
        }
    }

    impl PrekeyStore for FakePrekeyStore {
        fn find_account_by_handle(
            &mut self,
            user_handle: &str,
        ) -> Result<Option<PrekeyAccountRecord>, StoreError> {
            Ok(self
                .accounts
                .iter()
                .find(|account| account.user_handle() == user_handle)
                .cloned())
        }

        fn find_account_by_id(
            &mut self,
            account_id: &str,
        ) -> Result<Option<PrekeyAccountRecord>, StoreError> {
            Ok(self
                .accounts
                .iter()
                .find(|account| account.id() == account_id)
                .cloned())
        }

        fn find_active_device(
            &mut self,
            _account_id: &str,
            device_id: &str,
        ) -> Result<Option<PrekeyDeviceRecord>, StoreError> {
            Ok(self
                .devices
                .iter()
                .find(|device| device.device_id() == device_id)
                .cloned())
        }

        fn list_active_devices(
            &mut self,
            _account_id: &str,
        ) -> Result<Vec<PrekeyDeviceRecord>, StoreError> {
            Ok(self.devices.clone())
        }

        fn publish_prekeys(
            &mut self,
            account_id: &str,
            device_id: &str,
            signed_prekey: &SignedPrekey,
            one_time_prekeys: &[OneTimePrekey],
        ) -> Result<PublishedPrekeys, StoreError> {
            self.published.push(PublishedRequest {
                account_id: account_id.to_owned(),
                device_id: device_id.to_owned(),
                signed_prekey_id: signed_prekey.prekey_id.clone(),
                one_time_count: one_time_prekeys.len(),
            });
            let mut inserted = 0;
            for prekey in one_time_prekeys {
                if self.duplicate_one_time_ids.insert(prekey.prekey_id.clone()) {
                    inserted += 1;
                }
            }

            Ok(PublishedPrekeys {
                signed_prekey_id: signed_prekey.prekey_id.clone(),
                one_time_prekeys_added: inserted,
            })
        }

        fn get_signed_prekey(
            &mut self,
            account_id: &str,
            device_id: &str,
        ) -> Result<Option<SignedPrekey>, StoreError> {
            Ok(self
                .signed_prekeys
                .iter()
                .find(|stored| stored.account_id == account_id && stored.device_id == device_id)
                .map(|stored| stored.signed_prekey.clone()))
        }

        fn consume_one_time_prekey(
            &mut self,
            account_id: &str,
            device_id: &str,
        ) -> Result<Option<OneTimePrekey>, StoreError> {
            let Some(prekey) = self.one_time_prekeys.iter_mut().find(|stored| {
                stored.account_id == account_id && stored.device_id == device_id && !stored.consumed
            }) else {
                return Ok(None);
            };
            prekey.consumed = true;
            self.consumed_one_time_ids
                .push(prekey.one_time_prekey.prekey_id.clone());
            Ok(Some(prekey.one_time_prekey.clone()))
        }

        fn enabled_push_modes(
            &mut self,
            account_id: &str,
            device_id: &str,
        ) -> Result<Vec<PushMode>, StoreError> {
            Ok(self
                .push_modes
                .iter()
                .filter(|stored| stored.account_id == account_id && stored.device_id == device_id)
                .map(|stored| stored.mode)
                .collect())
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredSignedPrekey {
        account_id: String,
        device_id: String,
        signed_prekey: SignedPrekey,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredOneTimePrekey {
        account_id: String,
        device_id: String,
        one_time_prekey: OneTimePrekey,
        consumed: bool,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredPushMode {
        account_id: String,
        device_id: String,
        mode: PushMode,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct PublishedRequest {
        account_id: String,
        device_id: String,
        signed_prekey_id: String,
        one_time_count: usize,
    }

    impl PublishedRequest {
        fn device_id(&self) -> &str {
            &self.device_id
        }
    }
}
