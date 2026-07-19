//! `PostgreSQL` persistence adapter for federation routes.
//!
//! Federation ingress stores only encrypted mailbox blobs and routing receipts. Push jobs may carry the privacy-safe
//! `push_kind` hint, but call-oriented hints are suppressed before persistence.

use crate::auth::{normalize_handle, DeviceCertificate};
use crate::auth_service::{ApiError, StoreError};
use crate::devices::PushMode;
use crate::federation::{
    receipt_for_delivery_status, validate_federation_deliveries,
    verify_incoming_federation_request, FederationDeliveryStatus, FederationTrustState,
    FederationVerification, FederationVerificationInput, ServerKeysPayload,
};
use crate::federation_service::{
    FederationAuthContext, FederationAuthRequest, FederationDeliverRequest,
    FederationDeliverResponse, FederationDeliveryReceipt, FederationPrekeyRequest,
    FederationPrekeyResponse, FederationReceiptInsert, FederationReceiptsRequest,
    FederationReceiptsResponse, FederationServerKeysConfig, FederationServerRecord,
    FederationService,
};
use crate::messages::{
    is_uuid_like, normalized_delivery, push_kind_for_job, DeliveryUnit, PushKind, WakeupClass,
};
use crate::prekey_service::{PrekeyAccountRecord, PrekeyDeviceRecord};
use crate::prekeys::{
    build_prekey_bundle, bundle_push_mode, one_time_for_bundle, OneTimePrekey, PrekeyBundle,
    PrekeyBundleInput, SignedPrekey,
};
use crate::realtime::RealtimeHub;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine as _;
use ed25519_dalek::SigningKey;
use sqlx::postgres::PgRow;
use sqlx::{PgPool, Row};
use std::convert::TryFrom;
use std::env;

const ED25519_PRIVATE_KEY_LENGTH: usize = 32;
const ED25519_PUBLIC_KEY_LENGTH: usize = 32;
const ED25519_PKCS8_PREFIX: [u8; 16] = [
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];
const ED25519_SPKI_PREFIX: [u8; 12] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

const FIND_TRUSTED_SERVER_SQL: &str = r"
SELECT domain, key_id, server_sign_pub, trust_state
FROM federation_servers
WHERE domain = $1
";

const TOUCH_TRUSTED_SERVER_SQL: &str = r"
UPDATE federation_servers
SET last_seen_at = CURRENT_TIMESTAMP
WHERE domain = $1
";

const FIND_PREKEY_ACCOUNT_SQL: &str = r"
SELECT
  a.id::TEXT AS id,
  a.user_handle,
  i.ik_sign_pub AS account_sign_pub,
  COALESCE(s.allow_search, TRUE) AS allow_search
FROM accounts a
JOIN identity_keys i ON i.account_id = a.id
LEFT JOIN account_settings s ON s.account_id = a.id
WHERE a.user_handle = $1
";

const LIST_PREKEY_DEVICES_SQL: &str = r"
SELECT
  device_id,
  dk_sign_pub,
  dk_dh_pub,
  device_certificate_chain::TEXT AS device_certificate_chain
FROM devices
WHERE account_id = $1::uuid
  AND state = 'active'
ORDER BY created_at DESC
";

const GET_SIGNED_PREKEY_SQL: &str = r#"
SELECT
  prekey_id,
  signed_prekey_pub,
  signature,
  to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS expires_at
FROM signed_prekeys
WHERE account_id = $1::uuid
  AND device_id = $2
"#;

const CONSUME_ONE_TIME_PREKEY_SQL: &str = r"
WITH picked AS (
  SELECT id
  FROM one_time_prekeys
  WHERE account_id = $1::uuid
    AND device_id = $2
    AND consumed_at IS NULL
  ORDER BY created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
UPDATE one_time_prekeys
SET consumed_at = CURRENT_TIMESTAMP
WHERE id IN (SELECT id FROM picked)
RETURNING prekey_id, prekey_pub
";

const ENABLED_PUSH_MODES_SQL: &str = r"
SELECT push_mode
FROM device_push_tokens
WHERE account_id = $1::uuid
  AND device_id = $2
  AND push_enabled = TRUE
ORDER BY updated_at DESC, created_at DESC
";

const FIND_DELIVERY_ACCOUNT_SQL: &str = r"
SELECT id::TEXT AS id
FROM accounts
WHERE user_handle = $1
";

const LIST_ACTIVE_DEVICE_IDS_SQL: &str = r"
SELECT device_id
FROM devices
WHERE account_id = $1::uuid
  AND state = 'active'
ORDER BY created_at DESC
";

const DEVICE_FAST_NOTIFY_SQL: &str = r"
SELECT EXISTS (
  SELECT 1
  FROM device_push_tokens
  WHERE account_id = $1::uuid
    AND device_id = $2
    AND push_enabled = TRUE
    AND push_mode = 'fast_notify'
) AS allowed
";

const INSERT_FEDERATION_DELIVERY_SQL: &str = r"
INSERT INTO mailbox_blobs (
  owner_account_id,
  owner_device_id,
  sender_server,
  message_id,
  delivery_id,
  ciphertext_blob,
  envelope,
  ttl_sec,
  expires_at
)
VALUES ($1::uuid, $2, $3, $4::uuid, $5::uuid, $6, $7::jsonb, $8, to_timestamp($9::double precision / 1000.0))
ON CONFLICT (owner_account_id, owner_device_id, delivery_id) DO NOTHING
";

const INSERT_PUSH_JOB_SQL: &str = r"
INSERT INTO push_jobs (
  owner_account_id,
  owner_device_id,
  from_device_id,
  push_kind,
  wakeup_class,
  message_id,
  delivery_id,
  dedupe_key
)
VALUES ($1::uuid, $2, $3, $4, $5, $6::uuid, $7::uuid, $8)
ON CONFLICT (owner_account_id, owner_device_id, delivery_id) DO NOTHING
";

const INSERT_RECEIPT_SQL: &str = r"
INSERT INTO federation_receipts (from_server, message_id, delivery_id, status, detail)
VALUES ($1, $2::uuid, $3::uuid, $4, $5)
ON CONFLICT (from_server, delivery_id, status) DO NOTHING
";

/// Async `PostgreSQL` repository for federation route boundaries.
#[derive(Debug, Clone)]
pub struct PostgresFederationRepository {
    pool: PgPool,
    realtime: Option<RealtimeHub>,
}

impl PostgresFederationRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self {
            pool,
            realtime: None,
        }
    }

    #[must_use]
    pub const fn with_realtime(pool: PgPool, realtime: RealtimeHub) -> Self {
        Self {
            pool,
            realtime: Some(realtime),
        }
    }

    /// Builds the public federation server-key payload from server-side signing configuration.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when signing key configuration is missing or invalid.
    pub fn server_keys(server_name: &str, now_ms: u64) -> Result<ServerKeysPayload, ApiError> {
        FederationService::server_keys(&FederationServerKeysConfig {
            server_name: server_name.to_owned(),
            key_id: server_key_id(),
            public_key: server_public_key_from_env()?,
            now_ms,
        })
    }

    /// Returns federation prekey bundles for a searchable local account.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the account is unavailable or durable storage fails.
    pub async fn prekeys(
        &self,
        request: &FederationPrekeyRequest,
    ) -> Result<FederationPrekeyResponse, ApiError> {
        let user_handle = normalize_handle(&request.user_handle);
        let account = self.find_prekey_account(&user_handle).await?;
        let Some(account) = account.filter(PrekeyAccountRecord::allow_search) else {
            return Err(ApiError::not_found("Unavailable"));
        };

        let devices = self.list_prekey_devices(account.id()).await?;
        let mut bundles = Vec::new();
        for device in devices {
            if request
                .device_id
                .as_deref()
                .is_some_and(|device_id| device_id != device.device_id())
            {
                continue;
            }
            if let Some(bundle) = self
                .bundle_for_device(&account, &device, request.peek)
                .await?
            {
                bundles.push(bundle);
            }
        }

        Ok(FederationPrekeyResponse { bundles })
    }

    /// Verifies signed federation headers against the trusted-server table.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the request is unsigned, stale, blocked, invalid, or storage fails.
    pub async fn authenticate(
        &self,
        request: &FederationAuthRequest<'_>,
    ) -> Result<FederationAuthContext, ApiError> {
        let trusted = self
            .find_trusted_server(request.headers.x_mesh_server)
            .await?;
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
                self.touch_seen(server_domain).await?;
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

    /// Receives encrypted delivery units from a verified remote server.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation or durable storage side effects fail.
    pub async fn deliver(
        &self,
        auth: &FederationAuthContext,
        request: &FederationDeliverRequest,
        now_ms: u64,
    ) -> Result<FederationDeliverResponse, ApiError> {
        validate_federation_deliveries(&request.deliveries)
            .map_err(|_| ApiError::bad_request("Invalid federation delivery payload"))?;

        let mut receipts = Vec::with_capacity(request.deliveries.len());
        for raw_delivery in &request.deliveries {
            let delivery = normalized_delivery(raw_delivery);
            let target_handle = normalize_handle(&delivery.to_user);
            let account = self.find_delivery_account(&target_handle).await?;
            let Some(account_id) = account else {
                self.record_unavailable_delivery(auth, &delivery, &mut receipts)
                    .await?;
                continue;
            };

            let devices = self.list_active_device_ids(&account_id).await?;
            let target_devices = target_device_ids(&devices, &delivery.to_device_id);
            if target_devices.is_empty() {
                self.record_unavailable_delivery(auth, &delivery, &mut receipts)
                    .await?;
                continue;
            }

            for device_id in &target_devices {
                let inserted = self
                    .insert_federation_delivery(
                        &account_id,
                        device_id,
                        &auth.server_domain,
                        &delivery,
                        now_ms,
                    )
                    .await?;
                if inserted {
                    let push_created = self
                        .create_push_job(&account_id, device_id, &delivery)
                        .await?;
                    if push_created {
                        self.notify_sync_blob_available(
                            &account_id,
                            &delivery.message_id,
                            &delivery.delivery_id,
                            device_id,
                        );
                    }
                }
            }

            receipts.push(FederationDeliveryReceipt {
                delivery_id: delivery.delivery_id.clone(),
                status: FederationDeliveryStatus::Accepted,
            });
            self.create_receipt(FederationReceiptInsert {
                from_server: &auth.server_domain,
                message_id: &delivery.message_id,
                delivery_id: &delivery.delivery_id,
                status: receipt_for_delivery_status(FederationDeliveryStatus::Accepted),
                detail: None,
            })
            .await?;
        }

        Ok(FederationDeliverResponse { receipts })
    }

    /// Persists delivery receipts from a verified remote server.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when receipt ids are invalid or durable storage fails.
    pub async fn receipts(
        &self,
        auth: &FederationAuthContext,
        request: &FederationReceiptsRequest,
    ) -> Result<FederationReceiptsResponse, ApiError> {
        validate_receipts_request(request)?;
        for receipt in &request.receipts {
            self.create_receipt(FederationReceiptInsert {
                from_server: &auth.server_domain,
                message_id: &receipt.message_id,
                delivery_id: &receipt.delivery_id,
                status: receipt.status,
                detail: receipt.detail.as_deref(),
            })
            .await?;
        }

        Ok(FederationReceiptsResponse {
            accepted: request.receipts.len(),
        })
    }

    async fn find_trusted_server(
        &self,
        domain: &str,
    ) -> Result<Option<FederationServerRecord>, ApiError> {
        sqlx::query(FIND_TRUSTED_SERVER_SQL)
            .bind(domain)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| federation_server_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    async fn touch_seen(&self, domain: &str) -> Result<(), ApiError> {
        sqlx::query(TOUCH_TRUSTED_SERVER_SQL)
            .bind(domain)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| ApiError::internal())
    }

    async fn find_prekey_account(
        &self,
        user_handle: &str,
    ) -> Result<Option<PrekeyAccountRecord>, ApiError> {
        sqlx::query(FIND_PREKEY_ACCOUNT_SQL)
            .bind(user_handle)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| account_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    async fn list_prekey_devices(
        &self,
        account_id: &str,
    ) -> Result<Vec<PrekeyDeviceRecord>, ApiError> {
        let rows = sqlx::query(LIST_PREKEY_DEVICES_SQL)
            .bind(account_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        rows.iter()
            .map(device_from_row)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| ApiError::internal())
    }

    async fn get_signed_prekey(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<SignedPrekey>, ApiError> {
        sqlx::query(GET_SIGNED_PREKEY_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| signed_prekey_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    async fn consume_one_time_prekey(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<OneTimePrekey>, ApiError> {
        let mut transaction = self.pool.begin().await.map_err(|_| ApiError::internal())?;
        let row = sqlx::query(CONSUME_ONE_TIME_PREKEY_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        transaction
            .commit()
            .await
            .map_err(|_| ApiError::internal())?;

        row.map(|value| one_time_prekey_from_row(&value))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    async fn enabled_push_modes(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Vec<PushMode>, ApiError> {
        let rows = sqlx::query(ENABLED_PUSH_MODES_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        rows.iter()
            .map(push_mode_from_row)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| ApiError::internal())
    }

    async fn bundle_for_device(
        &self,
        account: &PrekeyAccountRecord,
        device: &PrekeyDeviceRecord,
        peek: bool,
    ) -> Result<Option<PrekeyBundle>, ApiError> {
        let signed_prekey = self
            .get_signed_prekey(account.id(), device.device_id())
            .await?;
        let one_time = if peek {
            None
        } else {
            self.consume_one_time_prekey(account.id(), device.device_id())
                .await?
        };
        let modes = self
            .enabled_push_modes(account.id(), device.device_id())
            .await?;
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

    async fn find_delivery_account(&self, user_handle: &str) -> Result<Option<String>, ApiError> {
        sqlx::query(FIND_DELIVERY_ACCOUNT_SQL)
            .bind(user_handle)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| row.try_get("id").map_err(|_| ApiError::internal()))
            .transpose()
    }

    async fn list_active_device_ids(&self, account_id: &str) -> Result<Vec<String>, ApiError> {
        let rows = sqlx::query(LIST_ACTIVE_DEVICE_IDS_SQL)
            .bind(account_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        rows.iter()
            .map(|row| row.try_get("device_id").map_err(|_| ApiError::internal()))
            .collect()
    }

    async fn device_allows_fast_notify(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<bool, ApiError> {
        sqlx::query_scalar::<_, bool>(DEVICE_FAST_NOTIFY_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())
    }

    async fn insert_federation_delivery(
        &self,
        owner_account_id: &str,
        owner_device_id: &str,
        sender_server: &str,
        delivery: &DeliveryUnit,
        now_ms: u64,
    ) -> Result<bool, ApiError> {
        let envelope = serde_json::to_string(&FederationDeliveryEnvelope {
            relay_type: "federation",
            sender_server,
        })
        .map_err(|_| ApiError::internal())?;
        let expires_at_ms = now_ms.saturating_add(delivery.ttl_sec.saturating_mul(1_000));
        let result = sqlx::query(INSERT_FEDERATION_DELIVERY_SQL)
            .bind(owner_account_id)
            .bind(owner_device_id)
            .bind(sender_server)
            .bind(&delivery.message_id)
            .bind(&delivery.delivery_id)
            .bind(&delivery.ciphertext_blob)
            .bind(envelope)
            .bind(i64::try_from(delivery.ttl_sec).map_err(|_| ApiError::internal())?)
            .bind(i64::try_from(expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(result.rows_affected() > 0)
    }

    async fn create_push_job(
        &self,
        owner_account_id: &str,
        owner_device_id: &str,
        delivery: &DeliveryUnit,
    ) -> Result<bool, ApiError> {
        let allowed_fast_notify = self
            .device_allows_fast_notify(owner_account_id, owner_device_id)
            .await?;
        let push_kind = push_kind_wire(push_kind_for_job(allowed_fast_notify, delivery.push_kind));
        let wakeup_class = wakeup_class_wire(delivery.wakeup_class.unwrap_or(WakeupClass::Generic));
        let result = sqlx::query(INSERT_PUSH_JOB_SQL)
            .bind(owner_account_id)
            .bind(owner_device_id)
            .bind(Option::<&str>::None)
            .bind(push_kind)
            .bind(wakeup_class)
            .bind(&delivery.message_id)
            .bind(&delivery.delivery_id)
            .bind(&delivery.delivery_id)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(result.rows_affected() > 0)
    }

    fn notify_sync_blob_available(
        &self,
        account_id: &str,
        message_id: &str,
        delivery_id: &str,
        device_id: &str,
    ) {
        if let Some(realtime) = self.realtime.as_ref() {
            realtime.notify_sync_blob_available(account_id, message_id, delivery_id, device_id);
        }
    }

    async fn record_unavailable_delivery(
        &self,
        auth: &FederationAuthContext,
        delivery: &DeliveryUnit,
        receipts: &mut Vec<FederationDeliveryReceipt>,
    ) -> Result<(), ApiError> {
        receipts.push(FederationDeliveryReceipt {
            delivery_id: delivery.delivery_id.clone(),
            status: FederationDeliveryStatus::Unavailable,
        });
        self.create_receipt(FederationReceiptInsert {
            from_server: &auth.server_domain,
            message_id: &delivery.message_id,
            delivery_id: &delivery.delivery_id,
            status: receipt_for_delivery_status(FederationDeliveryStatus::Unavailable),
            detail: Some("Unavailable"),
        })
        .await
    }

    async fn create_receipt(&self, input: FederationReceiptInsert<'_>) -> Result<(), ApiError> {
        sqlx::query(INSERT_RECEIPT_SQL)
            .bind(input.from_server)
            .bind(input.message_id)
            .bind(input.delivery_id)
            .bind(input.status.as_wire())
            .bind(input.detail)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| ApiError::internal())
    }
}

#[derive(serde::Serialize)]
struct FederationDeliveryEnvelope<'a> {
    relay_type: &'static str,
    sender_server: &'a str,
}

fn federation_server_from_row(row: &PgRow) -> Result<FederationServerRecord, StoreError> {
    Ok(FederationServerRecord {
        domain: row.try_get("domain").map_err(|_| StoreError)?,
        key_id: row.try_get("key_id").map_err(|_| StoreError)?,
        server_sign_pub: row.try_get("server_sign_pub").map_err(|_| StoreError)?,
        trust_state: trust_state_from_wire(
            row.try_get::<String, _>("trust_state")
                .map_err(|_| StoreError)?
                .as_str(),
        )
        .ok_or(StoreError)?,
    })
}

fn account_from_row(row: &PgRow) -> Result<PrekeyAccountRecord, StoreError> {
    Ok(PrekeyAccountRecord::new(
        row.try_get("id").map_err(|_| StoreError)?,
        row.try_get("user_handle").map_err(|_| StoreError)?,
        row.try_get("account_sign_pub").map_err(|_| StoreError)?,
        row.try_get("allow_search").map_err(|_| StoreError)?,
    ))
}

fn device_from_row(row: &PgRow) -> Result<PrekeyDeviceRecord, StoreError> {
    let raw_chain = row
        .try_get::<String, _>("device_certificate_chain")
        .map_err(|_| StoreError)?;
    let certificate_chain = parse_certificate_chain(&raw_chain)?;

    Ok(PrekeyDeviceRecord::new(
        row.try_get("device_id").map_err(|_| StoreError)?,
        row.try_get("dk_sign_pub").map_err(|_| StoreError)?,
        row.try_get("dk_dh_pub").map_err(|_| StoreError)?,
        certificate_chain,
    ))
}

fn signed_prekey_from_row(row: &PgRow) -> Result<SignedPrekey, StoreError> {
    Ok(SignedPrekey {
        prekey_id: row.try_get("prekey_id").map_err(|_| StoreError)?,
        signed_prekey_pub: row.try_get("signed_prekey_pub").map_err(|_| StoreError)?,
        signature: row.try_get("signature").map_err(|_| StoreError)?,
        expires_at: row.try_get("expires_at").map_err(|_| StoreError)?,
    })
}

fn one_time_prekey_from_row(row: &PgRow) -> Result<OneTimePrekey, StoreError> {
    Ok(OneTimePrekey {
        prekey_id: row.try_get("prekey_id").map_err(|_| StoreError)?,
        prekey_pub: row.try_get("prekey_pub").map_err(|_| StoreError)?,
    })
}

fn push_mode_from_row(row: &PgRow) -> Result<PushMode, StoreError> {
    let mode = row
        .try_get::<String, _>("push_mode")
        .map_err(|_| StoreError)?;
    Ok(if mode == PushMode::FastNotify.as_wire() {
        PushMode::FastNotify
    } else {
        PushMode::PrivacyFirst
    })
}

fn parse_certificate_chain(raw: &str) -> Result<Vec<DeviceCertificate>, StoreError> {
    serde_json::from_str(raw).map_err(|_| StoreError)
}

const fn trust_state_from_wire(value: &str) -> Option<FederationTrustState> {
    match value.as_bytes() {
        b"active" => Some(FederationTrustState::Active),
        b"blocked" => Some(FederationTrustState::Blocked),
        _ => None,
    }
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

const fn push_kind_wire(push_kind: Option<PushKind>) -> Option<&'static str> {
    match push_kind {
        Some(kind) => Some(kind.as_wire()),
        None => None,
    }
}

const fn wakeup_class_wire(wakeup_class: WakeupClass) -> &'static str {
    match wakeup_class {
        WakeupClass::Generic => "generic",
        WakeupClass::VoipOpaque => "voip_opaque",
    }
}

fn server_key_id() -> String {
    env::var("SERVER_SIGN_KEY_ID").unwrap_or_else(|_| "ed25519:1".to_owned())
}

fn server_public_key_from_env() -> Result<String, ApiError> {
    if let Ok(public_key) = env::var("SERVER_SIGN_PUBLIC_KEY") {
        let trimmed = public_key.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_owned());
        }
    }

    let private_key = env::var("SERVER_SIGN_PRIVATE_KEY").map_err(|_| ApiError::internal())?;
    let seed = private_seed_bytes(&private_key).map_err(|_| ApiError::internal())?;
    let signing_key = SigningKey::from_bytes(&seed);
    let public_key = signing_key.verifying_key().to_bytes();
    let mut spki = Vec::with_capacity(ED25519_SPKI_PREFIX.len() + ED25519_PUBLIC_KEY_LENGTH);
    spki.extend_from_slice(&ED25519_SPKI_PREFIX);
    spki.extend_from_slice(&public_key);

    Ok(STANDARD.encode(spki))
}

fn private_seed_bytes(value: &str) -> Result<[u8; ED25519_PRIVATE_KEY_LENGTH], StoreError> {
    let decoded = decode_private_key_material(value)?;
    if decoded.len() == ED25519_PRIVATE_KEY_LENGTH {
        return decoded.as_slice().try_into().map_err(|_| StoreError);
    }

    let Some(seed) = decoded.as_slice().strip_prefix(&ED25519_PKCS8_PREFIX) else {
        return Err(StoreError);
    };
    if seed.len() != ED25519_PRIVATE_KEY_LENGTH {
        return Err(StoreError);
    }

    seed.try_into().map_err(|_| StoreError)
}

fn decode_private_key_material(value: &str) -> Result<Vec<u8>, StoreError> {
    let trimmed = value.trim();
    let pem_marker = concat!("BEGIN ", "PRIVATE KEY");
    if trimmed.contains(pem_marker) {
        let body = trimmed
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with("-----"))
            .collect::<String>();
        return decode_base64_or_url(&body);
    }

    decode_base64_or_url(trimmed)
}

fn decode_base64_or_url(value: &str) -> Result<Vec<u8>, StoreError> {
    for engine in [&STANDARD, &STANDARD_NO_PAD, &URL_SAFE, &URL_SAFE_NO_PAD] {
        if let Ok(decoded) = engine.decode(value) {
            return Ok(decoded);
        }
    }

    Err(StoreError)
}

#[must_use]
pub const fn federation_repository_query_contract() -> &'static [&'static str] {
    &[
        FIND_TRUSTED_SERVER_SQL,
        TOUCH_TRUSTED_SERVER_SQL,
        FIND_PREKEY_ACCOUNT_SQL,
        LIST_PREKEY_DEVICES_SQL,
        GET_SIGNED_PREKEY_SQL,
        CONSUME_ONE_TIME_PREKEY_SQL,
        ENABLED_PUSH_MODES_SQL,
        FIND_DELIVERY_ACCOUNT_SQL,
        LIST_ACTIVE_DEVICE_IDS_SQL,
        DEVICE_FAST_NOTIFY_SQL,
        INSERT_FEDERATION_DELIVERY_SQL,
        INSERT_PUSH_JOB_SQL,
        INSERT_RECEIPT_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        federation_repository_query_contract, private_seed_bytes, push_kind_wire,
        trust_state_from_wire, CONSUME_ONE_TIME_PREKEY_SQL, DEVICE_FAST_NOTIFY_SQL,
        ED25519_PKCS8_PREFIX, FIND_TRUSTED_SERVER_SQL, INSERT_FEDERATION_DELIVERY_SQL,
        INSERT_PUSH_JOB_SQL, INSERT_RECEIPT_SQL,
    };
    use crate::federation::FederationTrustState;
    use crate::messages::PushKind;
    use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
    use base64::Engine as _;

    #[test]
    fn queries_are_parameterized_and_privacy_scoped() {
        for query in federation_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(FIND_TRUSTED_SERVER_SQL.contains("WHERE domain = $1"));
        assert!(CONSUME_ONE_TIME_PREKEY_SQL.contains("FOR UPDATE SKIP LOCKED"));
        assert!(DEVICE_FAST_NOTIFY_SQL.contains("push_mode = 'fast_notify'"));
        assert!(INSERT_FEDERATION_DELIVERY_SQL.contains("ciphertext_blob"));
        assert!(INSERT_FEDERATION_DELIVERY_SQL.contains("ON CONFLICT"));
        assert!(INSERT_PUSH_JOB_SQL.contains("push_kind"));
        assert!(INSERT_PUSH_JOB_SQL.contains("ON CONFLICT"));
        assert!(INSERT_RECEIPT_SQL.contains("ON CONFLICT"));
    }

    #[test]
    fn parses_trust_state_and_private_key_material() {
        assert_eq!(
            trust_state_from_wire("active"),
            Some(FederationTrustState::Active)
        );
        assert_eq!(
            trust_state_from_wire("blocked"),
            Some(FederationTrustState::Blocked)
        );
        assert_eq!(trust_state_from_wire("unknown"), None);

        let seed = [7_u8; 32];
        let seed_raw = STANDARD.encode(seed);
        assert_eq!(private_seed_bytes(&seed_raw), Ok(seed));

        let mut pkcs8 = Vec::from(ED25519_PKCS8_PREFIX);
        pkcs8.extend_from_slice(&seed);
        let pkcs8_raw = URL_SAFE_NO_PAD.encode(pkcs8);
        assert_eq!(private_seed_bytes(&pkcs8_raw), Ok(seed));
    }

    #[test]
    fn push_kind_wire_keeps_call_metadata_suppressed_by_policy() {
        assert_eq!(push_kind_wire(None), None);
        assert_eq!(push_kind_wire(Some(PushKind::Message)), Some("message"));
        assert_eq!(push_kind_wire(Some(PushKind::Other)), Some("other"));
    }
}
