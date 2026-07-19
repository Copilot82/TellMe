//! `PostgreSQL` persistence adapter for secure media upload initialization.

use crate::auth_service::StoreError;
use crate::auth_service::{ApiError, AuthenticatedSession};
use crate::media::{hash_capability_token, media_paths, DEFAULT_MEDIA_TTL_SEC};
use crate::media_service::{
    MarkUploadedVerified, MediaObjectRecord, MediaStatus, MediaUploadInitRequest,
    MediaUploadInitResponse,
};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use sqlx::postgres::PgRow;
use sqlx::{PgPool, Row};
use std::convert::TryFrom;
use std::env;
use time::OffsetDateTime;

const MIN_MEDIA_TTL_SEC: u64 = 60;
const MAX_MEDIA_TTL_SEC: u64 = 60 * 60 * 24 * 30;
const MEDIA_CAPABILITY_BYTES: usize = 32;
const MEDIA_STORAGE_KEY_BYTES: usize = 24;
const DEFAULT_MEDIA_BUCKET: &str = "messenger-cipher-media";

const INSERT_PENDING_MEDIA_SQL: &str = r"
INSERT INTO media_objects (
  owner_account_id,
  mime_hint,
  size_hint,
  expires_at,
  storage_bucket,
  storage_key,
  download_capability_hash,
  origin_server
)
VALUES ($1::uuid, $2, $3, to_timestamp($4::double precision / 1000.0), $5, $6, $7, $8)
RETURNING id::TEXT AS id
";

const FIND_MEDIA_BY_ID_SQL: &str = r"
SELECT
  id::TEXT AS id,
  owner_account_id::TEXT AS owner_account_id,
  status,
  download_capability_hash,
  storage_bucket,
  storage_key
FROM media_objects
WHERE id = $1::uuid
";

const FIND_MEDIA_FOR_CAPABILITY_SQL: &str = r"
SELECT
  id::TEXT AS id,
  owner_account_id::TEXT AS owner_account_id,
  status,
  download_capability_hash,
  storage_bucket,
  storage_key
FROM media_objects
WHERE id = $1::uuid
  AND download_capability_hash = $2
  AND status = 'uploaded_verified'
  AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
LIMIT 1
";

const MARK_REJECTED_SQL: &str = r"
UPDATE media_objects
SET status = 'rejected',
    rejection_reason = $2,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid
";

const IDENTITY_PUBLIC_KEY_SQL: &str = r"
SELECT ik_sign_pub
FROM identity_keys
WHERE account_id = $1::uuid
";

const MARK_UPLOADED_VERIFIED_SQL: &str = r"
UPDATE media_objects
SET status = 'uploaded_verified',
    hash_ciphertext = $2,
    ciphertext_size = $3,
    scan_verdict = $4,
    risk_flags = $5::jsonb,
    scanner_version = $6,
    rules_version = $7,
    signer_user_handle = $8,
    signer_device_id = $9,
    attestation_signature = $10,
    uploaded_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid
RETURNING
  id::TEXT AS id,
  owner_account_id::TEXT AS owner_account_id,
  status,
  download_capability_hash,
  storage_bucket,
  storage_key
";

/// Async `PostgreSQL` repository for media upload-init route boundaries.
#[derive(Debug, Clone)]
pub struct PostgresMediaRepository {
    pool: PgPool,
}

impl PostgresMediaRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Creates a pending media row with a hashed download capability.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation, randomness, time conversion, or durable storage fails.
    pub async fn upload_init(
        &self,
        auth: &AuthenticatedSession,
        request: &MediaUploadInitRequest,
        now_ms: u64,
        origin_server: &str,
    ) -> Result<MediaUploadInitResponse, ApiError> {
        validate_upload_init_request(request)?;
        let ttl_sec = request.ttl_sec.unwrap_or(DEFAULT_MEDIA_TTL_SEC);
        let expires_at_ms = now_ms.saturating_add(ttl_sec.saturating_mul(1_000));
        let expires_at = iso_millis(expires_at_ms)?;
        let capability_token = random_base64_url(MEDIA_CAPABILITY_BYTES)?;
        let storage_bucket = media_bucket_name();
        let storage_key = format!("media/{}", random_base64_url(MEDIA_STORAGE_KEY_BYTES)?);
        let size_hint = request
            .size_hint
            .map(i64::try_from)
            .transpose()
            .map_err(|_| ApiError::internal())?;
        let row = sqlx::query(INSERT_PENDING_MEDIA_SQL)
            .bind(&auth.account_id)
            .bind(nullable_string(request.mime_hint.as_deref()))
            .bind(size_hint)
            .bind(i64::try_from(expires_at_ms).map_err(|_| ApiError::internal())?)
            .bind(&storage_bucket)
            .bind(&storage_key)
            .bind(hash_capability_token(&capability_token))
            .bind(origin_server)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        let media_id: String = row.try_get("id").map_err(|_| ApiError::internal())?;
        let paths = media_paths(&media_id);

        Ok(MediaUploadInitResponse {
            media_id,
            upload_path: paths.upload_path,
            download_path: paths.download_path,
            download_capability: capability_token,
            origin_server: origin_server.to_owned(),
            expires_at,
        })
    }

    /// Finds one media metadata row by id.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when durable storage cannot be queried.
    pub async fn find_media_by_id(
        &self,
        media_id: &str,
    ) -> Result<Option<MediaObjectRecord>, ApiError> {
        sqlx::query(FIND_MEDIA_BY_ID_SQL)
            .bind(media_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| media_record_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    /// Finds uploaded media by id and hashed download capability.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when durable storage cannot be queried.
    pub async fn find_media_for_capability(
        &self,
        media_id: &str,
        capability_hash: &str,
    ) -> Result<Option<MediaObjectRecord>, ApiError> {
        sqlx::query(FIND_MEDIA_FOR_CAPABILITY_SQL)
            .bind(media_id)
            .bind(capability_hash)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| media_record_from_row(&row))
            .transpose()
            .map_err(|_| ApiError::internal())
    }

    /// Marks a media row rejected without storing plaintext or ciphertext.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when durable storage cannot update the row.
    pub async fn mark_rejected(&self, media_id: &str, reason: &str) -> Result<(), ApiError> {
        sqlx::query(MARK_REJECTED_SQL)
            .bind(media_id)
            .bind(reason)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| ApiError::internal())
    }

    /// Finds the account signing public key used to verify client media attestation.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when durable storage cannot be queried.
    pub async fn identity_public_key(&self, account_id: &str) -> Result<Option<String>, ApiError> {
        sqlx::query_scalar::<_, String>(IDENTITY_PUBLIC_KEY_SQL)
            .bind(account_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())
    }

    /// Marks media uploaded and scan-verified after object storage accepts ciphertext.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when durable storage cannot update the row.
    pub async fn mark_uploaded_verified(
        &self,
        input: &MarkUploadedVerified,
    ) -> Result<MediaObjectRecord, ApiError> {
        let risk_flags =
            serde_json::to_string(&input.risk_flags).map_err(|_| ApiError::internal())?;
        let ciphertext_size =
            i64::try_from(input.ciphertext_size).map_err(|_| ApiError::internal())?;
        let scanner_version =
            i64::try_from(input.scanner_version).map_err(|_| ApiError::internal())?;
        let rules_version = i64::try_from(input.rules_version).map_err(|_| ApiError::internal())?;

        let row = sqlx::query(MARK_UPLOADED_VERIFIED_SQL)
            .bind(&input.id)
            .bind(&input.hash_ciphertext)
            .bind(ciphertext_size)
            .bind(&input.scan_verdict)
            .bind(risk_flags)
            .bind(scanner_version)
            .bind(rules_version)
            .bind(&input.signer_user_handle)
            .bind(&input.signer_device_id)
            .bind(&input.attestation_signature)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        media_record_from_row(&row).map_err(|_| ApiError::internal())
    }
}

fn validate_upload_init_request(request: &MediaUploadInitRequest) -> Result<(), ApiError> {
    if request
        .mime_hint
        .as_ref()
        .is_some_and(|value| value.len() > 255)
        || request
            .ttl_sec
            .is_some_and(|ttl| !(MIN_MEDIA_TTL_SEC..=MAX_MEDIA_TTL_SEC).contains(&ttl))
    {
        return Err(ApiError::bad_request("Invalid media upload init payload"));
    }

    Ok(())
}

fn nullable_string(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn media_bucket_name() -> String {
    env::var("MEDIA_BUCKET")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_MEDIA_BUCKET.to_owned())
}

fn random_base64_url(byte_len: usize) -> Result<String, ApiError> {
    let mut bytes = vec![0_u8; byte_len];
    getrandom::getrandom(&mut bytes).map_err(|_| ApiError::internal())?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
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

fn media_record_from_row(row: &PgRow) -> Result<MediaObjectRecord, StoreError> {
    Ok(MediaObjectRecord {
        id: row.try_get("id").map_err(|_| StoreError)?,
        owner_account_id: row.try_get("owner_account_id").map_err(|_| StoreError)?,
        status: media_status_from_wire(
            row.try_get::<String, _>("status")
                .map_err(|_| StoreError)?
                .as_str(),
        )
        .ok_or(StoreError)?,
        download_capability_hash: row
            .try_get("download_capability_hash")
            .map_err(|_| StoreError)?,
        storage_bucket: row.try_get("storage_bucket").map_err(|_| StoreError)?,
        storage_key: row.try_get("storage_key").map_err(|_| StoreError)?,
    })
}

const fn media_status_from_wire(value: &str) -> Option<MediaStatus> {
    match value.as_bytes() {
        b"pending" => Some(MediaStatus::Pending),
        b"uploaded_verified" => Some(MediaStatus::UploadedVerified),
        b"rejected" => Some(MediaStatus::Rejected),
        b"deleted" => Some(MediaStatus::Deleted),
        _ => None,
    }
}

#[must_use]
pub const fn media_repository_query_contract() -> &'static [&'static str] {
    &[
        INSERT_PENDING_MEDIA_SQL,
        FIND_MEDIA_BY_ID_SQL,
        FIND_MEDIA_FOR_CAPABILITY_SQL,
        MARK_REJECTED_SQL,
        IDENTITY_PUBLIC_KEY_SQL,
        MARK_UPLOADED_VERIFIED_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        media_repository_query_contract, media_status_from_wire, random_base64_url,
        validate_upload_init_request, FIND_MEDIA_FOR_CAPABILITY_SQL, IDENTITY_PUBLIC_KEY_SQL,
        INSERT_PENDING_MEDIA_SQL, MARK_UPLOADED_VERIFIED_SQL, MEDIA_CAPABILITY_BYTES,
        MEDIA_STORAGE_KEY_BYTES,
    };
    use crate::media_service::MediaStatus;
    use crate::media_service::MediaUploadInitRequest;

    #[test]
    fn pending_media_insert_is_parameterized_and_hash_only() {
        for query in media_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(INSERT_PENDING_MEDIA_SQL.contains("owner_account_id"));
        assert!(INSERT_PENDING_MEDIA_SQL.contains("download_capability_hash"));
        assert!(INSERT_PENDING_MEDIA_SQL.contains("to_timestamp($4::double precision / 1000.0)"));
        assert!(!INSERT_PENDING_MEDIA_SQL.contains("download_capability,"));
        assert!(FIND_MEDIA_FOR_CAPABILITY_SQL.contains("download_capability_hash = $2"));
        assert!(FIND_MEDIA_FOR_CAPABILITY_SQL.contains("status = 'uploaded_verified'"));
        assert!(IDENTITY_PUBLIC_KEY_SQL.contains("account_id = $1::uuid"));
        assert!(MARK_UPLOADED_VERIFIED_SQL.contains("risk_flags = $5::jsonb"));
    }

    #[test]
    fn upload_init_validation_matches_current_bounds() {
        assert!(validate_upload_init_request(&MediaUploadInitRequest {
            mime_hint: Some("application/octet-stream".to_owned()),
            size_hint: Some(0),
            ttl_sec: Some(60),
        })
        .is_ok());
        assert!(validate_upload_init_request(&MediaUploadInitRequest {
            mime_hint: Some("x".repeat(256)),
            size_hint: None,
            ttl_sec: None,
        })
        .is_err());
        assert!(validate_upload_init_request(&MediaUploadInitRequest {
            mime_hint: None,
            size_hint: None,
            ttl_sec: Some(59),
        })
        .is_err());
    }

    #[test]
    fn media_tokens_and_storage_keys_are_url_safe() {
        let capability = random_base64_url(MEDIA_CAPABILITY_BYTES);
        let storage = random_base64_url(MEDIA_STORAGE_KEY_BYTES);

        assert!(capability.is_ok());
        assert!(storage.is_ok());
        let (Ok(capability), Ok(storage)) = (capability, storage) else {
            return;
        };
        assert_eq!(capability.len(), 43);
        assert_eq!(storage.len(), 32);
        assert!(!capability.contains('='));
        assert!(!storage.contains('='));
    }

    #[test]
    fn media_status_parser_accepts_current_secure_states() {
        assert_eq!(
            media_status_from_wire("pending"),
            Some(MediaStatus::Pending)
        );
        assert_eq!(
            media_status_from_wire("uploaded_verified"),
            Some(MediaStatus::UploadedVerified)
        );
        assert_eq!(
            media_status_from_wire("rejected"),
            Some(MediaStatus::Rejected)
        );
        assert_eq!(
            media_status_from_wire("deleted"),
            Some(MediaStatus::Deleted)
        );
        assert_eq!(media_status_from_wire("uploaded"), None);
    }
}
