//! `PostgreSQL` persistence adapter for prekey routes.
//!
//! The adapter mirrors the current TypeScript hard-cutover queries and keeps all public lookup behavior in the Rust
//! service contract: hidden accounts stay indistinguishable from missing accounts, one-time prekeys are consumed
//! transactionally, and push metadata is reduced to the allowed privacy mode.

use crate::auth::DeviceCertificate;
use crate::auth_service::{ApiError, AuthenticatedSession, StoreError};
use crate::devices::PushMode;
use crate::prekey_service::{
    PrekeyAccountRecord, PrekeyBundlesResponse, PrekeyDeviceRecord, PrekeyLookupRequest,
    PublishedPrekeys, SelfPrekeyRequest,
};
use crate::prekeys::{
    build_prekey_bundle, bundle_push_mode, normalize_prekey_user_query, one_time_for_bundle,
    validate_publish_request, OneTimePrekey, PrekeyBundle, PrekeyBundleInput, PrekeyError,
    PrekeyPublishRequest, SignedPrekey,
};
use sqlx::postgres::PgRow;
use sqlx::{PgPool, Row};
use std::convert::TryFrom;

const FIND_ACCOUNT_BY_HANDLE_SQL: &str = r"
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

const FIND_ACCOUNT_BY_ID_SQL: &str = r"
SELECT
  a.id::TEXT AS id,
  a.user_handle,
  i.ik_sign_pub AS account_sign_pub,
  COALESCE(s.allow_search, TRUE) AS allow_search
FROM accounts a
JOIN identity_keys i ON i.account_id = a.id
LEFT JOIN account_settings s ON s.account_id = a.id
WHERE a.id = $1::uuid
";

const FIND_ACTIVE_DEVICE_SQL: &str = r"
SELECT
  device_id,
  dk_sign_pub,
  dk_dh_pub,
  device_certificate_chain::TEXT AS device_certificate_chain
FROM devices
WHERE account_id = $1::uuid
  AND device_id = $2
  AND state = 'active'
";

const LIST_ACTIVE_DEVICES_SQL: &str = r"
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

const UPSERT_SIGNED_PREKEY_SQL: &str = r"
INSERT INTO signed_prekeys (account_id, device_id, prekey_id, signed_prekey_pub, signature, expires_at)
VALUES ($1::uuid, $2, $3, $4, $5, $6::timestamptz)
ON CONFLICT (account_id, device_id)
DO UPDATE SET
  prekey_id = EXCLUDED.prekey_id,
  signed_prekey_pub = EXCLUDED.signed_prekey_pub,
  signature = EXCLUDED.signature,
  expires_at = EXCLUDED.expires_at,
  created_at = CURRENT_TIMESTAMP
RETURNING prekey_id
";

const INSERT_ONE_TIME_PREKEY_SQL: &str = r"
INSERT INTO one_time_prekeys (account_id, device_id, prekey_id, prekey_pub)
VALUES ($1::uuid, $2, $3, $4)
ON CONFLICT (account_id, device_id, prekey_id) DO NOTHING
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

/// Async `PostgreSQL` repository for prekey service boundaries.
#[derive(Debug, Clone)]
pub struct PostgresPrekeyRepository {
    pool: PgPool,
}

impl PostgresPrekeyRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Publishes the authenticated device's signed and one-time prekeys transactionally.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for contract violations or durable storage failures.
    pub async fn publish(
        &self,
        auth: &AuthenticatedSession,
        request: &PrekeyPublishRequest,
    ) -> Result<PublishedPrekeys, ApiError> {
        if let Err(error) = validate_publish_request(request, &auth.device_id, true) {
            return Err(publish_validation_error(&error));
        }

        let device = self
            .find_active_device(&auth.account_id, &auth.device_id)
            .await?;
        if device.is_none() {
            return Err(ApiError::not_found("Device not found"));
        }

        let mut transaction = self.pool.begin().await.map_err(|_| ApiError::internal())?;
        let signed_row = sqlx::query(UPSERT_SIGNED_PREKEY_SQL)
            .bind(&auth.account_id)
            .bind(&auth.device_id)
            .bind(&request.signed_prekey.prekey_id)
            .bind(&request.signed_prekey.signed_prekey_pub)
            .bind(&request.signed_prekey.signature)
            .bind(request.signed_prekey.expires_at.as_deref())
            .fetch_one(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        let signed_prekey_id = signed_row
            .try_get::<String, _>("prekey_id")
            .map_err(|_| ApiError::internal())?;

        let mut one_time_prekeys_added = 0_usize;
        for prekey in &request.one_time_prekeys {
            let result = sqlx::query(INSERT_ONE_TIME_PREKEY_SQL)
                .bind(&auth.account_id)
                .bind(&auth.device_id)
                .bind(&prekey.prekey_id)
                .bind(&prekey.prekey_pub)
                .execute(&mut *transaction)
                .await
                .map_err(|_| ApiError::internal())?;
            let affected =
                usize::try_from(result.rows_affected()).map_err(|_| ApiError::internal())?;
            one_time_prekeys_added += affected;
        }

        transaction
            .commit()
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(PublishedPrekeys {
            signed_prekey_id,
            one_time_prekeys_added,
        })
    }

    /// Looks up public prekey bundles for a searchable account handle.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for invalid queries, hidden users, missing users, or storage failures.
    pub async fn lookup(
        &self,
        request: &PrekeyLookupRequest,
    ) -> Result<PrekeyBundlesResponse, ApiError> {
        let Some(user_handle) = normalize_prekey_user_query(request.user.as_deref()) else {
            return Err(ApiError::bad_request("user is required"));
        };
        let account = self.find_account_by_handle(&user_handle).await?;
        let Some(account) = account.filter(PrekeyAccountRecord::allow_search) else {
            return Err(ApiError::not_found("Unavailable"));
        };

        self.build_bundles(&account, request.device_id.as_deref(), request.peek)
            .await
    }

    /// Looks up bundles for the authenticated account without applying public-search visibility.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the account is gone or storage fails.
    pub async fn lookup_self(
        &self,
        auth: &AuthenticatedSession,
        request: &SelfPrekeyRequest,
    ) -> Result<PrekeyBundlesResponse, ApiError> {
        let account = self.find_account_by_id(&auth.account_id).await?;
        let Some(account) = account else {
            return Err(ApiError::not_found("Account not found"));
        };

        self.build_bundles(&account, request.device_id.as_deref(), request.peek)
            .await
    }

    async fn find_account_by_handle(
        &self,
        user_handle: &str,
    ) -> Result<Option<PrekeyAccountRecord>, ApiError> {
        sqlx::query(FIND_ACCOUNT_BY_HANDLE_SQL)
            .bind(user_handle)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| account_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    async fn find_account_by_id(
        &self,
        account_id: &str,
    ) -> Result<Option<PrekeyAccountRecord>, ApiError> {
        sqlx::query(FIND_ACCOUNT_BY_ID_SQL)
            .bind(account_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| account_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    async fn find_active_device(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<PrekeyDeviceRecord>, ApiError> {
        sqlx::query(FIND_ACTIVE_DEVICE_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| device_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    async fn list_active_devices(
        &self,
        account_id: &str,
    ) -> Result<Vec<PrekeyDeviceRecord>, ApiError> {
        let rows = sqlx::query(LIST_ACTIVE_DEVICES_SQL)
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

    async fn build_bundles(
        &self,
        account: &PrekeyAccountRecord,
        target_device_id: Option<&str>,
        peek: bool,
    ) -> Result<PrekeyBundlesResponse, ApiError> {
        let devices = self.list_active_devices(account.id()).await?;
        let mut bundles = Vec::new();
        for device in devices {
            if target_device_id.is_some_and(|target| target != device.device_id()) {
                continue;
            }
            if let Some(bundle) = self.bundle_for_device(account, &device, peek).await? {
                bundles.push(bundle);
            }
        }

        Ok(PrekeyBundlesResponse { bundles })
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

#[must_use]
pub const fn prekey_repository_query_contract() -> &'static [&'static str] {
    &[
        FIND_ACCOUNT_BY_HANDLE_SQL,
        FIND_ACCOUNT_BY_ID_SQL,
        FIND_ACTIVE_DEVICE_SQL,
        LIST_ACTIVE_DEVICES_SQL,
        UPSERT_SIGNED_PREKEY_SQL,
        INSERT_ONE_TIME_PREKEY_SQL,
        GET_SIGNED_PREKEY_SQL,
        CONSUME_ONE_TIME_PREKEY_SQL,
        ENABLED_PUSH_MODES_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        parse_certificate_chain, prekey_repository_query_contract, CONSUME_ONE_TIME_PREKEY_SQL,
        ENABLED_PUSH_MODES_SQL, FIND_ACCOUNT_BY_ID_SQL, GET_SIGNED_PREKEY_SQL,
        INSERT_ONE_TIME_PREKEY_SQL, UPSERT_SIGNED_PREKEY_SQL,
    };
    use crate::auth::CertificateIssuerKind;
    use crate::devices::PushMode;
    use crate::prekeys::{OneTimePrekey, PrekeyBundle, SignedPrekey};

    #[test]
    fn queries_are_parameterized_and_keep_uuid_casts_explicit() {
        for query in prekey_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(FIND_ACCOUNT_BY_ID_SQL.contains("a.id = $1::uuid"));
        assert!(UPSERT_SIGNED_PREKEY_SQL.contains("VALUES ($1::uuid"));
        assert!(UPSERT_SIGNED_PREKEY_SQL.contains("$6::timestamptz"));
        assert!(GET_SIGNED_PREKEY_SQL.contains("AT TIME ZONE 'UTC'"));
        assert!(INSERT_ONE_TIME_PREKEY_SQL.contains("ON CONFLICT"));
        assert!(CONSUME_ONE_TIME_PREKEY_SQL.contains("FOR UPDATE SKIP LOCKED"));
        assert!(ENABLED_PUSH_MODES_SQL.contains("push_enabled = TRUE"));
    }

    #[test]
    fn certificate_chain_json_matches_ios_wire_shape() {
        let raw = r#"[
          {
            "device_certificate_version": 2,
            "account_handle": "@alice:example.com",
            "device_id": "ios-primary",
            "device_sign_pub": "dk-sign",
            "device_dh_pub": "dk-dh",
            "issuer_kind": "account",
            "issuer_device_id": null,
            "parent_certificate_id": null,
            "issued_at": "2026-01-01T00:00:00Z",
            "expires_at": null,
            "signature": "sig"
          }
        ]"#;

        let parsed = parse_certificate_chain(raw);

        assert!(parsed.is_ok());
        let Ok(certificates) = parsed else {
            return;
        };
        assert_eq!(certificates.len(), 1);
        let Some(certificate) = certificates.first() else {
            return;
        };
        assert_eq!(certificate.issuer_kind, CertificateIssuerKind::Account);
        assert_eq!(certificate.device_id, "ios-primary");
    }

    #[test]
    fn prekey_bundle_serializes_push_mode_and_optional_one_time_prekey() {
        let bundle = PrekeyBundle {
            protocol_version: 2,
            user_handle: "@alice:example.com".to_owned(),
            account_sign_pub: "ik-sign".to_owned(),
            device_id: "ios-primary".to_owned(),
            device_sign_pub: "dk-sign".to_owned(),
            device_dh_pub: "dk-dh".to_owned(),
            device_certificate_chain: Vec::new(),
            signed_prekey: SignedPrekey {
                prekey_id: "spk-1".to_owned(),
                signed_prekey_pub: "spk-pub".to_owned(),
                signature: "spk-sig".to_owned(),
                expires_at: None,
            },
            one_time_prekey: Some(OneTimePrekey {
                prekey_id: "otp-1".to_owned(),
                prekey_pub: "otp-pub".to_owned(),
            }),
            push_mode: PushMode::FastNotify,
        };

        let serialized = serde_json::to_string(&bundle);

        assert!(serialized.is_ok());
        let Ok(serialized) = serialized else {
            return;
        };
        assert!(serialized.contains(r#""push_mode":"fast_notify""#));
        assert!(serialized.contains(r#""one_time_prekey":{"#));
    }
}
