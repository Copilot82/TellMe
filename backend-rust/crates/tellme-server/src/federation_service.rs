//! Service-level federation route contract.
//!
//! Federation ingress only routes encrypted delivery envelopes. The server may persist routing metadata, delivery state,
//! and privacy-safe push hints, but it must not interpret ciphertext or expose plaintext call signaling.

use crate::auth::normalize_handle;
use crate::auth_service::{ApiError, StoreError};
use crate::devices::PushMode;
use crate::federation::{
    receipt_for_delivery_status, validate_federation_deliveries,
    verify_incoming_federation_request, FederationDeliveryStatus, FederationHeaders,
    FederationReceiptStatus, FederationTrustState, FederationVerification,
    FederationVerificationInput, ServerKeysPayload, TrustedFederationServer,
};
use crate::messages::{
    is_uuid_like, normalized_delivery, push_kind_for_job, DeliveryUnit, PushKind, WakeupClass,
};
use crate::prekey_service::{PrekeyAccountRecord, PrekeyDeviceRecord};
use crate::prekeys::{
    build_prekey_bundle, bundle_push_mode, one_time_for_bundle, OneTimePrekey, PrekeyBundle,
    PrekeyBundleInput, SignedPrekey,
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

const SERVER_KEYS_TTL_MS: u64 = 24 * 60 * 60 * 1_000;

/// Trusted federation server row owned by the storage boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FederationServerRecord {
    pub domain: String,
    pub key_id: String,
    pub server_sign_pub: String,
    pub trust_state: FederationTrustState,
}

impl FederationServerRecord {
    #[must_use]
    pub fn as_trusted(&self) -> TrustedFederationServer<'_> {
        TrustedFederationServer {
            domain: &self.domain,
            key_id: &self.key_id,
            server_sign_pub: &self.server_sign_pub,
            trust_state: self.trust_state,
        }
    }
}

/// Account row needed for federation delivery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FederationDeliveryAccount {
    id: String,
}

impl FederationDeliveryAccount {
    #[must_use]
    pub const fn new(id: String) -> Self {
        Self { id }
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }
}

/// Storage and side-effect boundary for federation routes.
// Federation delivery keeps remote trust checks separate from local mailbox insertion.
pub trait FederationStore {
    /// Finds a trusted federation server by domain.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_trusted_server(
        &mut self,
        domain: &str,
    ) -> Result<Option<FederationServerRecord>, StoreError>;

    /// Marks a trusted federation server as recently seen.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the row.
    fn touch_seen(&mut self, domain: &str) -> Result<(), StoreError>;

    /// Finds a searchable local account for federation prekey lookup.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_prekey_account(
        &mut self,
        user_handle: &str,
    ) -> Result<Option<PrekeyAccountRecord>, StoreError>;

    /// Lists active local devices for federation prekey lookup.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn list_prekey_devices(
        &mut self,
        account_id: &str,
    ) -> Result<Vec<PrekeyDeviceRecord>, StoreError>;

    /// Fetches the current signed prekey for a local device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn get_signed_prekey(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<SignedPrekey>, StoreError>;

    /// Consumes one one-time prekey for a local device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot consume the prekey.
    fn consume_one_time_prekey(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<OneTimePrekey>, StoreError>;

    /// Lists enabled push privacy modes for a local device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn enabled_push_modes(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Vec<PushMode>, StoreError>;

    /// Finds a local account for encrypted delivery ingress.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_delivery_account(
        &mut self,
        user_handle: &str,
    ) -> Result<Option<FederationDeliveryAccount>, StoreError>;

    /// Lists active local device ids for encrypted delivery ingress.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn list_active_device_ids(&mut self, account_id: &str) -> Result<Vec<String>, StoreError>;

    /// Checks whether a target device has opted into fast notification metadata.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn device_allows_fast_notify(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<bool, StoreError>;

    /// Inserts one federation mailbox delivery. Returns `false` for duplicate delivery ids.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the mailbox blob.
    fn insert_federation_delivery(
        &mut self,
        input: FederationDeliveryInsert<'_>,
    ) -> Result<bool, StoreError>;

    /// Creates a privacy-safe push job for one inserted federation delivery.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot create the push job.
    fn create_push_job(&mut self, input: FederationPushJobInsert<'_>) -> Result<bool, StoreError>;

    /// Emits sync notification to currently connected local devices.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when the side-effect boundary fails.
    fn notify_sync_blob_available(
        &mut self,
        account_id: &str,
        message_id: &str,
        delivery_id: &str,
        device_id: &str,
    ) -> Result<(), StoreError>;

    /// Persists a federation delivery receipt.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the receipt.
    fn create_receipt(&mut self, input: FederationReceiptInsert<'_>) -> Result<(), StoreError>;
}

/// Server-key route deterministic context.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FederationServerKeysConfig {
    pub server_name: String,
    pub key_id: String,
    pub public_key: String,
    pub now_ms: u64,
}

/// Signed federation auth request context.
#[derive(Debug, Clone, Copy)]
pub struct FederationAuthRequest<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub body_raw: &'a str,
    pub headers: FederationHeaders<'a>,
    pub now_ms: u64,
}

/// Verified federation sender context.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FederationAuthContext {
    pub server_domain: String,
    pub key_id: String,
}

/// Query for `/federation/v1/prekeys/:userHandle`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FederationPrekeyRequest {
    pub user_handle: String,
    pub device_id: Option<String>,
    pub peek: bool,
}

/// Response body for federation prekey lookup.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FederationPrekeyResponse {
    pub bundles: Vec<PrekeyBundle>,
}

/// Request body for `/federation/v1/deliver`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct FederationDeliverRequest {
    pub from_server: String,
    pub deliveries: Vec<DeliveryUnit>,
}

/// One federation delivery receipt returned to the sender.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FederationDeliveryReceipt {
    pub delivery_id: String,
    pub status: FederationDeliveryStatus,
}

/// Response body for `/federation/v1/deliver`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FederationDeliverResponse {
    pub receipts: Vec<FederationDeliveryReceipt>,
}

/// Incoming receipt item for `/federation/v1/receipts`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct FederationReceiptInput {
    pub message_id: String,
    pub delivery_id: String,
    pub status: FederationReceiptStatus,
    pub detail: Option<String>,
}

/// Request body for `/federation/v1/receipts`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct FederationReceiptsRequest {
    pub receipts: Vec<FederationReceiptInput>,
}

/// Response body for `/federation/v1/receipts`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct FederationReceiptsResponse {
    pub accepted: usize,
}

/// Federation mailbox insert input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FederationDeliveryInsert<'a> {
    pub owner_account_id: &'a str,
    pub owner_device_id: &'a str,
    pub sender_server: &'a str,
    pub delivery: &'a DeliveryUnit,
    pub relay_type: &'static str,
}

/// Federation push job insert input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FederationPushJobInsert<'a> {
    pub owner_account_id: &'a str,
    pub owner_device_id: &'a str,
    pub from_device_id: Option<&'a str>,
    pub message_id: &'a str,
    pub delivery_id: &'a str,
    pub push_kind: Option<PushKind>,
    pub wakeup_class: WakeupClass,
}

/// Federation receipt insert input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FederationReceiptInsert<'a> {
    pub from_server: &'a str,
    pub message_id: &'a str,
    pub delivery_id: &'a str,
    pub status: FederationReceiptStatus,
    pub detail: Option<&'a str>,
}

/// Service implementation for federation routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FederationService;

impl FederationService {
    /// Builds the public server-key payload.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the validity timestamp cannot be represented.
    pub fn server_keys(config: &FederationServerKeysConfig) -> Result<ServerKeysPayload, ApiError> {
        Ok(ServerKeysPayload {
            server_name: config.server_name.clone(),
            key_id: config.key_id.clone(),
            public_key: config.public_key.clone(),
            valid_until: iso_millis(config.now_ms.saturating_add(SERVER_KEYS_TTL_MS))?,
            algorithm: "Ed25519",
        })
    }

    /// Verifies signed federation headers and touches the trusted server row.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the request is unsigned, stale, blocked, invalid, or storage fails.
    pub fn authenticate<S: FederationStore>(
        store: &mut S,
        request: &FederationAuthRequest<'_>,
    ) -> Result<FederationAuthContext, ApiError> {
        let trusted = store
            .find_trusted_server(request.headers.x_mesh_server)
            .map_err(|_| ApiError::internal())?;
        let trusted_view = trusted.as_ref().map(FederationServerRecord::as_trusted);
        let verification_input = FederationVerificationInput {
            method: request.method,
            path: request.path,
            body_raw: request.body_raw,
            headers: request.headers,
            trusted_server: trusted_view,
            now_ms: request.now_ms,
        };
        let verification = verify_incoming_federation_request(&verification_input)
            .map_err(|_| ApiError::unauthorized("Invalid federation signature"))?;

        match verification {
            FederationVerification::Verified {
                server_domain,
                key_id,
            } => {
                store
                    .touch_seen(server_domain)
                    .map_err(|_| ApiError::internal())?;
                Ok(FederationAuthContext {
                    server_domain: server_domain.to_owned(),
                    key_id: key_id.to_owned(),
                })
            }
            FederationVerification::Unauthorized => {
                Err(ApiError::unauthorized("Invalid federation signature"))
            }
            FederationVerification::Blocked => {
                Err(ApiError::forbidden("Federation server is blocked"))
            }
        }
    }

    /// Returns federation prekey bundles for a local searchable account.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the account is unavailable or storage fails.
    pub fn prekeys<S: FederationStore>(
        store: &mut S,
        request: &FederationPrekeyRequest,
    ) -> Result<FederationPrekeyResponse, ApiError> {
        let user_handle = normalize_handle(&request.user_handle);
        let account = store
            .find_prekey_account(&user_handle)
            .map_err(|_| ApiError::internal())?;
        let Some(account) = account.filter(PrekeyAccountRecord::allow_search) else {
            return Err(ApiError::not_found("Unavailable"));
        };

        let devices = store
            .list_prekey_devices(account.id())
            .map_err(|_| ApiError::internal())?;
        let mut bundles = Vec::new();
        for device in devices {
            if request
                .device_id
                .as_deref()
                .is_some_and(|device_id| device_id != device.device_id())
            {
                continue;
            }
            if let Some(bundle) =
                federation_bundle_for_device(store, &account, &device, request.peek)?
            {
                bundles.push(bundle);
            }
        }

        Ok(FederationPrekeyResponse { bundles })
    }

    /// Receives encrypted delivery units from a verified remote server.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation or storage side effects fail.
    pub fn deliver<S: FederationStore>(
        store: &mut S,
        auth: &FederationAuthContext,
        request: &FederationDeliverRequest,
    ) -> Result<FederationDeliverResponse, ApiError> {
        validate_federation_deliveries(&request.deliveries)
            .map_err(|_| ApiError::bad_request("Invalid federation delivery payload"))?;

        let mut receipts = Vec::with_capacity(request.deliveries.len());
        for raw_delivery in &request.deliveries {
            let delivery = normalized_delivery(raw_delivery);
            let target_handle = normalize_handle(&delivery.to_user);
            let account = store
                .find_delivery_account(&target_handle)
                .map_err(|_| ApiError::internal())?;
            let Some(account) = account else {
                record_unavailable_delivery(store, auth, &delivery, &mut receipts)?;
                continue;
            };

            let devices = store
                .list_active_device_ids(account.id())
                .map_err(|_| ApiError::internal())?;
            let target_devices = target_device_ids(&devices, &delivery.to_device_id);
            if target_devices.is_empty() {
                record_unavailable_delivery(store, auth, &delivery, &mut receipts)?;
                continue;
            }

            for device_id in &target_devices {
                let inserted = store
                    .insert_federation_delivery(FederationDeliveryInsert {
                        owner_account_id: account.id(),
                        owner_device_id: device_id,
                        sender_server: &auth.server_domain,
                        delivery: &delivery,
                        relay_type: "federation",
                    })
                    .map_err(|_| ApiError::internal())?;
                if inserted {
                    create_federation_push_and_notify(store, account.id(), device_id, &delivery)?;
                }
            }

            receipts.push(FederationDeliveryReceipt {
                delivery_id: delivery.delivery_id.clone(),
                status: FederationDeliveryStatus::Accepted,
            });
            create_status_receipt(
                store,
                auth,
                &delivery,
                FederationDeliveryStatus::Accepted,
                None,
            )?;
        }

        Ok(FederationDeliverResponse { receipts })
    }

    /// Persists delivery receipts from a verified remote server.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when receipt ids are invalid or storage fails.
    pub fn receipts<S: FederationStore>(
        store: &mut S,
        auth: &FederationAuthContext,
        request: &FederationReceiptsRequest,
    ) -> Result<FederationReceiptsResponse, ApiError> {
        validate_receipts_request(request)?;
        for receipt in &request.receipts {
            store
                .create_receipt(FederationReceiptInsert {
                    from_server: &auth.server_domain,
                    message_id: &receipt.message_id,
                    delivery_id: &receipt.delivery_id,
                    status: receipt.status,
                    detail: receipt.detail.as_deref(),
                })
                .map_err(|_| ApiError::internal())?;
        }

        Ok(FederationReceiptsResponse {
            accepted: request.receipts.len(),
        })
    }
}

fn federation_bundle_for_device<S: FederationStore>(
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

    Ok(build_prekey_bundle(&PrekeyBundleInput {
        user_handle: account.user_handle(),
        account_sign_pub: account.account_sign_pub(),
        device_id: device.device_id(),
        device_sign_pub: device.device_sign_pub(),
        device_dh_pub: device.device_dh_pub(),
        device_certificate_chain: device.device_certificate_chain(),
        signed_prekey: signed_prekey.as_ref(),
        one_time_prekey: one_time_prekey.as_ref(),
        push_mode: bundle_push_mode(&modes),
    }))
}

fn record_unavailable_delivery<S: FederationStore>(
    store: &mut S,
    auth: &FederationAuthContext,
    delivery: &DeliveryUnit,
    receipts: &mut Vec<FederationDeliveryReceipt>,
) -> Result<(), ApiError> {
    receipts.push(FederationDeliveryReceipt {
        delivery_id: delivery.delivery_id.clone(),
        status: FederationDeliveryStatus::Unavailable,
    });
    create_status_receipt(
        store,
        auth,
        delivery,
        FederationDeliveryStatus::Unavailable,
        Some("Unavailable"),
    )
}

fn create_federation_push_and_notify<S: FederationStore>(
    store: &mut S,
    owner_account_id: &str,
    owner_device_id: &str,
    delivery: &DeliveryUnit,
) -> Result<(), ApiError> {
    let allowed_fast_notify = store
        .device_allows_fast_notify(owner_account_id, owner_device_id)
        .map_err(|_| ApiError::internal())?;
    let push_created = store
        .create_push_job(FederationPushJobInsert {
            owner_account_id,
            owner_device_id,
            from_device_id: None,
            message_id: &delivery.message_id,
            delivery_id: &delivery.delivery_id,
            push_kind: push_kind_for_job(allowed_fast_notify, delivery.push_kind),
            wakeup_class: delivery.wakeup_class.unwrap_or(WakeupClass::Generic),
        })
        .map_err(|_| ApiError::internal())?;
    if push_created {
        store
            .notify_sync_blob_available(
                owner_account_id,
                &delivery.message_id,
                &delivery.delivery_id,
                owner_device_id,
            )
            .map_err(|_| ApiError::internal())?;
    }

    Ok(())
}

fn create_status_receipt<S: FederationStore>(
    store: &mut S,
    auth: &FederationAuthContext,
    delivery: &DeliveryUnit,
    status: FederationDeliveryStatus,
    detail: Option<&str>,
) -> Result<(), ApiError> {
    store
        .create_receipt(FederationReceiptInsert {
            from_server: &auth.server_domain,
            message_id: &delivery.message_id,
            delivery_id: &delivery.delivery_id,
            status: receipt_for_delivery_status(status),
            detail,
        })
        .map_err(|_| ApiError::internal())
}

fn validate_receipts_request(request: &FederationReceiptsRequest) -> Result<(), ApiError> {
    if request
        .receipts
        .iter()
        .any(|receipt| !is_uuid_like(&receipt.message_id) || !is_uuid_like(&receipt.delivery_id))
    {
        return Err(ApiError::bad_request("Invalid federation receipt payload"));
    }

    Ok(())
}

fn target_device_ids(devices: &[String], requested: &str) -> Vec<String> {
    if requested == "*" {
        return devices.to_vec();
    }

    devices
        .iter()
        .filter(|device_id| device_id.as_str() == requested)
        .cloned()
        .collect()
}

fn iso_millis(unix_ms: u64) -> Result<String, ApiError> {
    let seconds = i64::try_from(unix_ms / 1_000).map_err(|_| ApiError::internal())?;
    let millis = unix_ms % 1_000;
    let datetime =
        OffsetDateTime::from_unix_timestamp(seconds).map_err(|_| ApiError::internal())?;
    Ok(format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        datetime.year(),
        u8::from(datetime.month()),
        datetime.day(),
        datetime.hour(),
        datetime.minute(),
        datetime.second(),
        millis
    ))
}

#[cfg(test)]
mod tests {
    use super::{
        FederationAuthContext, FederationAuthRequest, FederationDeliverRequest,
        FederationDeliveryAccount, FederationDeliveryInsert, FederationPushJobInsert,
        FederationReceiptInput, FederationReceiptInsert, FederationReceiptsRequest,
        FederationServerKeysConfig, FederationServerRecord, FederationService, FederationStore,
    };
    use crate::auth_service::{ApiError, ApiStatus, StoreError};
    use crate::devices::PushMode;
    use crate::federation::{
        FederationDeliveryStatus, FederationHeaders, FederationReceiptStatus, FederationTrustState,
    };
    use crate::messages::{DeliveryUnit, PushKind, WakeupClass};
    use crate::prekey_service::{PrekeyAccountRecord, PrekeyDeviceRecord};
    use crate::prekeys::{OneTimePrekey, SignedPrekey};

    const ACCOUNT_ID: &str = "acc-1";
    const HANDLE: &str = "@alice:example.com";
    const DEVICE_ID: &str = "ios-primary";
    const REMOTE: &str = "trusted.example";
    const PUBLIC_KEY: &str = "tTR6QJyD4EwWjnsRFhWC+EfXNSkyax72lhNxPU8yrPc=";
    const BODY_RAW: &str = r#"{"deliveries":[]}"#;
    const BODY_HASH: &str = "cmMWKqmB5Y6wuP1LoFihsX/2IsHoeEgguOwfQH6b04Q=";
    const DATE: &str = "2026-02-26T12:00:00.000Z";
    const SIGNATURE: &str =
        "4Kj+7wdgDhDQTZjHMA0vDdkBJZH8Tbw7ADDbLwxK1tE6d78i55+ePuqV7Ns0WAySkAaAdY0bdprRumTu0lP6AQ==";
    const NOW_MS: u64 = 1_772_107_200_000;

    #[test]
    fn server_keys_publish_public_metadata_with_short_validity() {
        let payload = FederationService::server_keys(&FederationServerKeysConfig {
            server_name: "example.com".to_owned(),
            key_id: "ed25519:current".to_owned(),
            public_key: "server-pub".to_owned(),
            now_ms: NOW_MS,
        });

        assert!(payload.is_ok());
        let Ok(payload) = payload else {
            return;
        };
        assert_eq!(payload.server_name, "example.com");
        assert_eq!(payload.algorithm, "Ed25519");
        assert_eq!(payload.valid_until, "2026-02-27T12:00:00.000Z");
    }

    #[test]
    fn authenticates_signed_federation_request_and_touches_sender() {
        let mut store = FakeFederationStore::with_trusted_server();
        let request = FederationAuthRequest {
            method: "POST",
            path: "/federation/test",
            body_raw: BODY_RAW,
            headers: headers(),
            now_ms: NOW_MS,
        };

        let response = FederationService::authenticate(&mut store, &request);

        assert_eq!(
            response,
            Ok(FederationAuthContext {
                server_domain: REMOTE.to_owned(),
                key_id: "ed25519:trusted".to_owned(),
            })
        );
        assert_eq!(store.touched.first().map(String::as_str), Some(REMOTE));
    }

    #[test]
    fn rejects_blocked_federation_sender() {
        let mut store = FakeFederationStore::with_trusted_server();
        if let Some(server) = store.trusted.first_mut() {
            server.trust_state = FederationTrustState::Blocked;
        }

        let response = FederationService::authenticate(
            &mut store,
            &FederationAuthRequest {
                method: "POST",
                path: "/federation/test",
                body_raw: BODY_RAW,
                headers: headers(),
                now_ms: NOW_MS,
            },
        );

        assert_eq!(
            response.err(),
            Some(ApiError::new(
                ApiStatus::Forbidden,
                "Federation server is blocked",
                None
            ))
        );
    }

    #[test]
    fn prekeys_hide_unsearchable_accounts_and_consume_one_time_prekey() {
        let mut store = FakeFederationStore::with_local_account();
        store.signed_prekeys.push(signed_prekey());
        store.one_time_prekeys.push(one_time_prekey());
        store.push_modes.push(PushMode::FastNotify);

        let response = FederationService::prekeys(
            &mut store,
            &super::FederationPrekeyRequest {
                user_handle: " @Alice:Example.COM ".to_owned(),
                device_id: Some(DEVICE_ID.to_owned()),
                peek: false,
            },
        );

        assert!(response.is_ok());
        let Ok(response) = response else {
            return;
        };
        assert_eq!(response.bundles.len(), 1);
        let Some(bundle) = response.bundles.first() else {
            return;
        };
        assert_eq!(bundle.user_handle, HANDLE);
        assert!(bundle.one_time_prekey.is_some());
        assert_eq!(bundle.push_mode, PushMode::FastNotify);
        assert!(store.one_time_prekeys.is_empty());

        let mut hidden = FakeFederationStore::with_local_account();
        if let Some(account) = hidden.prekey_accounts.first_mut() {
            *account = PrekeyAccountRecord::new(
                ACCOUNT_ID.to_owned(),
                HANDLE.to_owned(),
                "ik-sign".to_owned(),
                false,
            );
        }
        assert_eq!(
            FederationService::prekeys(
                &mut hidden,
                &super::FederationPrekeyRequest {
                    user_handle: HANDLE.to_owned(),
                    device_id: None,
                    peek: true,
                },
            )
            .err(),
            Some(ApiError::new(ApiStatus::NotFound, "Unavailable", None))
        );
    }

    #[test]
    fn deliver_routes_ciphertext_and_suppresses_plaintext_call_push_kind() {
        let mut store = FakeFederationStore::with_local_account();
        store.fast_notify = true;
        let request = FederationDeliverRequest {
            from_server: REMOTE.to_owned(),
            deliveries: vec![delivery(Some(PushKind::Call))],
        };

        let response = FederationService::deliver(&mut store, &auth_context(), &request);

        assert!(response.is_ok());
        let Ok(response) = response else {
            return;
        };
        assert_eq!(response.receipts.len(), 1);
        assert_eq!(
            response.receipts.first().map(|receipt| receipt.status),
            Some(FederationDeliveryStatus::Accepted)
        );
        assert_eq!(store.deliveries.len(), 1);
        assert_eq!(store.push_jobs.first().and_then(|job| job.push_kind), None);
        assert_eq!(store.notifications.len(), 1);
        assert_eq!(
            store.receipts.first().map(|receipt| receipt.status),
            Some(FederationReceiptStatus::Accepted)
        );
    }

    #[test]
    fn deliver_records_unavailable_without_mailbox_write() {
        let mut store = FakeFederationStore::default();
        let request = FederationDeliverRequest {
            from_server: REMOTE.to_owned(),
            deliveries: vec![delivery(Some(PushKind::Message))],
        };

        let response = FederationService::deliver(&mut store, &auth_context(), &request);

        assert!(response.is_ok());
        let Ok(response) = response else {
            return;
        };
        assert_eq!(
            response.receipts.first().map(|receipt| receipt.status),
            Some(FederationDeliveryStatus::Unavailable)
        );
        assert!(store.deliveries.is_empty());
        assert_eq!(
            store.receipts.first().map(|receipt| receipt.status),
            Some(FederationReceiptStatus::Rejected)
        );
        assert_eq!(
            store
                .receipts
                .first()
                .and_then(|receipt| receipt.detail.as_deref()),
            Some("Unavailable")
        );
    }

    #[test]
    fn receipts_validate_ids_and_persist_for_verified_sender() {
        let mut store = FakeFederationStore::default();
        let request = FederationReceiptsRequest {
            receipts: vec![FederationReceiptInput {
                message_id: "22222222-2222-4222-8222-222222222222".to_owned(),
                delivery_id: "11111111-1111-4111-8111-111111111111".to_owned(),
                status: FederationReceiptStatus::Acked,
                detail: Some("synced".to_owned()),
            }],
        };

        let response = FederationService::receipts(&mut store, &auth_context(), &request);

        assert_eq!(
            response,
            Ok(super::FederationReceiptsResponse { accepted: 1 })
        );
        assert_eq!(store.receipts.len(), 1);

        let invalid = FederationReceiptsRequest {
            receipts: vec![FederationReceiptInput {
                message_id: "not-a-uuid".to_owned(),
                delivery_id: "11111111-1111-4111-8111-111111111111".to_owned(),
                status: FederationReceiptStatus::Acked,
                detail: None,
            }],
        };
        assert_eq!(
            FederationService::receipts(&mut store, &auth_context(), &invalid).err(),
            Some(ApiError::new(
                ApiStatus::BadRequest,
                "Invalid federation receipt payload",
                None
            ))
        );
    }

    fn headers() -> FederationHeaders<'static> {
        FederationHeaders {
            x_mesh_server: REMOTE,
            x_mesh_key_id: "ed25519:trusted",
            x_mesh_date: DATE,
            x_mesh_signature: SIGNATURE,
            x_mesh_body_sha256: BODY_HASH,
        }
    }

    fn auth_context() -> FederationAuthContext {
        FederationAuthContext {
            server_domain: REMOTE.to_owned(),
            key_id: "ed25519:trusted".to_owned(),
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

    fn delivery(push_kind: Option<PushKind>) -> DeliveryUnit {
        DeliveryUnit {
            wire_version: 2,
            delivery_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            to_server: "example.com".to_owned(),
            to_user: HANDLE.to_owned(),
            to_device_id: DEVICE_ID.to_owned(),
            message_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            timestamp: "2026-03-01T00:00:00.000Z".to_owned(),
            ttl_sec: 600,
            ciphertext_blob: "ciphertext".to_owned(),
            push_kind,
            wakeup_class: None,
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakeFederationStore {
        trusted: Vec<FederationServerRecord>,
        touched: Vec<String>,
        prekey_accounts: Vec<PrekeyAccountRecord>,
        delivery_accounts: Vec<FederationDeliveryAccount>,
        devices: Vec<PrekeyDeviceRecord>,
        signed_prekeys: Vec<SignedPrekey>,
        one_time_prekeys: Vec<OneTimePrekey>,
        push_modes: Vec<PushMode>,
        active_device_ids: Vec<String>,
        fast_notify: bool,
        deliveries: Vec<String>,
        push_jobs: Vec<StoredPushJob>,
        notifications: Vec<String>,
        receipts: Vec<StoredReceipt>,
    }

    impl FakeFederationStore {
        fn with_trusted_server() -> Self {
            Self {
                trusted: vec![FederationServerRecord {
                    domain: REMOTE.to_owned(),
                    key_id: "ed25519:trusted".to_owned(),
                    server_sign_pub: PUBLIC_KEY.to_owned(),
                    trust_state: FederationTrustState::Active,
                }],
                ..Self::default()
            }
        }

        fn with_local_account() -> Self {
            Self {
                prekey_accounts: vec![PrekeyAccountRecord::new(
                    ACCOUNT_ID.to_owned(),
                    HANDLE.to_owned(),
                    "ik-sign".to_owned(),
                    true,
                )],
                delivery_accounts: vec![FederationDeliveryAccount::new(ACCOUNT_ID.to_owned())],
                devices: vec![PrekeyDeviceRecord::new(
                    DEVICE_ID.to_owned(),
                    "dk-sign".to_owned(),
                    "dk-dh".to_owned(),
                    Vec::new(),
                )],
                active_device_ids: vec![DEVICE_ID.to_owned()],
                ..Self::default()
            }
        }
    }

    impl FederationStore for FakeFederationStore {
        fn find_trusted_server(
            &mut self,
            domain: &str,
        ) -> Result<Option<FederationServerRecord>, StoreError> {
            Ok(self
                .trusted
                .iter()
                .find(|server| server.domain == domain)
                .cloned())
        }

        fn touch_seen(&mut self, domain: &str) -> Result<(), StoreError> {
            self.touched.push(domain.to_owned());
            Ok(())
        }

        fn find_prekey_account(
            &mut self,
            user_handle: &str,
        ) -> Result<Option<PrekeyAccountRecord>, StoreError> {
            Ok(self
                .prekey_accounts
                .iter()
                .find(|account| account.user_handle() == user_handle)
                .cloned())
        }

        fn list_prekey_devices(
            &mut self,
            _account_id: &str,
        ) -> Result<Vec<PrekeyDeviceRecord>, StoreError> {
            Ok(self.devices.clone())
        }

        fn get_signed_prekey(
            &mut self,
            _account_id: &str,
            _device_id: &str,
        ) -> Result<Option<SignedPrekey>, StoreError> {
            Ok(self.signed_prekeys.first().cloned())
        }

        fn consume_one_time_prekey(
            &mut self,
            _account_id: &str,
            _device_id: &str,
        ) -> Result<Option<OneTimePrekey>, StoreError> {
            if self.one_time_prekeys.is_empty() {
                return Ok(None);
            }
            Ok(Some(self.one_time_prekeys.remove(0)))
        }

        fn enabled_push_modes(
            &mut self,
            _account_id: &str,
            _device_id: &str,
        ) -> Result<Vec<PushMode>, StoreError> {
            Ok(self.push_modes.clone())
        }

        fn find_delivery_account(
            &mut self,
            user_handle: &str,
        ) -> Result<Option<FederationDeliveryAccount>, StoreError> {
            if user_handle == HANDLE {
                return Ok(self.delivery_accounts.first().cloned());
            }
            Ok(None)
        }

        fn list_active_device_ids(&mut self, _account_id: &str) -> Result<Vec<String>, StoreError> {
            Ok(self.active_device_ids.clone())
        }

        fn device_allows_fast_notify(
            &mut self,
            _account_id: &str,
            _device_id: &str,
        ) -> Result<bool, StoreError> {
            Ok(self.fast_notify)
        }

        fn insert_federation_delivery(
            &mut self,
            input: FederationDeliveryInsert<'_>,
        ) -> Result<bool, StoreError> {
            self.deliveries.push(format!(
                "{}:{}:{}",
                input.owner_account_id, input.owner_device_id, input.relay_type
            ));
            Ok(true)
        }

        fn create_push_job(
            &mut self,
            input: FederationPushJobInsert<'_>,
        ) -> Result<bool, StoreError> {
            self.push_jobs.push(StoredPushJob {
                delivery_id: input.delivery_id.to_owned(),
                push_kind: input.push_kind,
                wakeup_class: input.wakeup_class,
            });
            Ok(true)
        }

        fn notify_sync_blob_available(
            &mut self,
            _account_id: &str,
            _message_id: &str,
            delivery_id: &str,
            _device_id: &str,
        ) -> Result<(), StoreError> {
            self.notifications.push(delivery_id.to_owned());
            Ok(())
        }

        fn create_receipt(&mut self, input: FederationReceiptInsert<'_>) -> Result<(), StoreError> {
            self.receipts.push(StoredReceipt {
                from_server: input.from_server.to_owned(),
                delivery_id: input.delivery_id.to_owned(),
                status: input.status,
                detail: input.detail.map(ToOwned::to_owned),
            });
            Ok(())
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredPushJob {
        delivery_id: String,
        push_kind: Option<PushKind>,
        wakeup_class: WakeupClass,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredReceipt {
        from_server: String,
        delivery_id: String,
        status: FederationReceiptStatus,
        detail: Option<String>,
    }
}
