//! Service-level secure media upload/download contract.

use crate::auth_service::{ApiError, AuthenticatedSession, StoreError};
use crate::media::{
    bearer_capability_token, ciphertext_response_headers, hash_capability_token, media_paths,
    validate_media_upload, MediaRejectReason, MediaUploadAttestation, MediaUploadValidationInput,
    DEFAULT_MEDIA_TTL_SEC,
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

const MIN_MEDIA_TTL_SEC: u64 = 60;
const MAX_MEDIA_TTL_SEC: u64 = 60 * 60 * 24 * 30;

/// Media row states used by the route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaStatus {
    Pending,
    UploadedVerified,
    Rejected,
    Deleted,
}

/// Media object row needed by upload and download flows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaObjectRecord {
    pub id: String,
    pub owner_account_id: String,
    pub status: MediaStatus,
    pub download_capability_hash: String,
    pub storage_bucket: String,
    pub storage_key: String,
}

/// Pending media creation input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatePendingMedia {
    pub owner_account_id: String,
    pub mime_hint: Option<String>,
    pub size_hint: Option<u64>,
    pub expires_at: String,
    pub storage_bucket: String,
    pub storage_key: String,
    pub download_capability_hash: String,
    pub origin_server: String,
}

/// Verified upload metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkUploadedVerified {
    pub id: String,
    pub hash_ciphertext: String,
    pub ciphertext_size: usize,
    pub scan_verdict: String,
    pub risk_flags: Vec<String>,
    pub scanner_version: u64,
    pub rules_version: u64,
    pub signer_user_handle: String,
    pub signer_device_id: String,
    pub attestation_signature: String,
}

/// Storage and object-store boundary for media.
// Media records describe ciphertext blobs; decryption keys stay inside encrypted message payloads.
pub trait MediaStore {
    /// Creates a pending media object.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the row.
    fn create_pending_media(
        &mut self,
        input: CreatePendingMedia,
    ) -> Result<MediaObjectRecord, StoreError>;

    /// Finds a media object by id.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_media_by_id(&mut self, id: &str) -> Result<Option<MediaObjectRecord>, StoreError>;

    /// Finds uploaded media by id and capability hash.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_media_for_capability(
        &mut self,
        id: &str,
        capability_hash: &str,
    ) -> Result<Option<MediaObjectRecord>, StoreError>;

    /// Marks media rejected.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the row.
    fn mark_rejected(&mut self, id: &str, reason: &str) -> Result<(), StoreError>;

    /// Finds account identity public key.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn identity_public_key(&mut self, account_id: &str) -> Result<Option<String>, StoreError>;

    /// Stores ciphertext bytes in object storage.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when object storage cannot write the ciphertext.
    fn put_ciphertext(
        &mut self,
        storage_bucket: &str,
        storage_key: &str,
        ciphertext: &[u8],
    ) -> Result<(), StoreError>;

    /// Marks media uploaded and verified.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the row.
    fn mark_uploaded_verified(
        &mut self,
        input: MarkUploadedVerified,
    ) -> Result<MediaObjectRecord, StoreError>;

    /// Reads ciphertext bytes from object storage.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when object storage cannot read the ciphertext.
    fn get_ciphertext(
        &mut self,
        storage_bucket: &str,
        storage_key: &str,
    ) -> Result<Vec<u8>, StoreError>;
}

/// Request body for `/api/media/upload/init`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MediaUploadInitRequest {
    pub mime_hint: Option<String>,
    pub size_hint: Option<u64>,
    pub ttl_sec: Option<u64>,
}

/// Deterministic runtime values for upload init.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaUploadInitContext {
    pub now_ms: u64,
    pub media_id: String,
    pub storage_bucket: String,
    pub storage_key: String,
    pub capability_token: String,
    pub origin_server: String,
}

/// Response body for `/api/media/upload/init`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MediaUploadInitResponse {
    pub media_id: String,
    pub upload_path: String,
    pub download_path: String,
    pub download_capability: String,
    pub origin_server: String,
    pub expires_at: String,
}

/// Request body and headers for `/api/media/upload/:id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaUploadRequest {
    pub media_id: String,
    pub ciphertext: Vec<u8>,
    pub attestation: Option<MediaUploadAttestation>,
}

/// Runtime security policy for media upload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaUploadPolicy {
    pub min_scanner_version: u64,
    pub min_rules_version: u64,
}

/// Response body for verified uploads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MediaUploadResponse {
    pub media_id: String,
    pub uploaded: bool,
    pub attestation_payload: String,
}

/// Response for capability download.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaDownloadResponse {
    pub headers: Vec<(&'static str, &'static str)>,
    pub ciphertext: Vec<u8>,
}

/// Service implementation for media routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaService;

impl MediaService {
    /// Initializes a pending media object and download capability.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for invalid hints/ttl or storage failures.
    pub fn upload_init<S: MediaStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &MediaUploadInitRequest,
        context: &MediaUploadInitContext,
    ) -> Result<MediaUploadInitResponse, ApiError> {
        validate_upload_init_request(request)?;
        let ttl_sec = request.ttl_sec.unwrap_or(DEFAULT_MEDIA_TTL_SEC);
        let expires_at = iso_millis(context.now_ms.saturating_add(ttl_sec.saturating_mul(1_000)))?;
        let media = store
            .create_pending_media(CreatePendingMedia {
                owner_account_id: auth.account_id.clone(),
                mime_hint: request.mime_hint.clone(),
                size_hint: request.size_hint,
                expires_at: expires_at.clone(),
                storage_bucket: context.storage_bucket.clone(),
                storage_key: context.storage_key.clone(),
                download_capability_hash: hash_capability_token(&context.capability_token),
                origin_server: context.origin_server.clone(),
            })
            .map_err(|_| ApiError::internal())?;
        let paths = media_paths(&media.id);

        Ok(MediaUploadInitResponse {
            media_id: media.id,
            upload_path: paths.upload_path,
            download_path: paths.download_path,
            download_capability: context.capability_token.clone(),
            origin_server: context.origin_server.clone(),
            expires_at,
        })
    }

    /// Accepts a ciphertext upload after capability, scan, hash, and identity-signature verification.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` with the same rejection status and public error string as the TypeScript route.
    pub fn upload<S: MediaStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &MediaUploadRequest,
        policy: &MediaUploadPolicy,
    ) -> Result<MediaUploadResponse, ApiError> {
        let media = find_pending_media_for_upload(store, auth, &request.media_id)?;
        let Some(attestation) = request.attestation.as_ref() else {
            store
                .mark_rejected(&media.id, "missing_or_invalid_attestation_headers")
                .map_err(|_| ApiError::internal())?;
            return Err(ApiError::bad_request(
                "Secure media attestation is required",
            ));
        };
        let identity_public_key = store
            .identity_public_key(&auth.account_id)
            .map_err(|_| ApiError::internal())?;
        let Some(identity_public_key) = identity_public_key else {
            store
                .mark_rejected(&media.id, "missing_identity_key")
                .map_err(|_| ApiError::internal())?;
            return Err(ApiError::forbidden("Missing account identity key"));
        };
        let validation = MediaUploadValidationInput {
            media_id: &media.id,
            user_handle: &auth.user_handle,
            device_id: &auth.device_id,
            expected_capability_hash: &media.download_capability_hash,
            ciphertext: &request.ciphertext,
            attestation,
            min_scanner_version: policy.min_scanner_version,
            min_rules_version: policy.min_rules_version,
            identity_public_key: &identity_public_key,
        };
        let attestation_payload = match validate_media_upload(&validation) {
            Ok(payload) => payload,
            Err(crate::media::MediaError::Rejected(reason)) => {
                store
                    .mark_rejected(&media.id, reason.as_wire())
                    .map_err(|_| ApiError::internal())?;
                return Err(media_rejection_error(reason));
            }
            Err(crate::media::MediaError::InvalidVerdict) => {
                store
                    .mark_rejected(&media.id, "missing_or_invalid_attestation_headers")
                    .map_err(|_| ApiError::internal())?;
                return Err(ApiError::bad_request(
                    "Secure media attestation is required",
                ));
            }
        };

        store
            .put_ciphertext(
                &media.storage_bucket,
                &media.storage_key,
                &request.ciphertext,
            )
            .map_err(|_| ApiError::internal())?;
        store
            .mark_uploaded_verified(MarkUploadedVerified {
                id: media.id.clone(),
                hash_ciphertext: attestation.ciphertext_sha256.clone(),
                ciphertext_size: request.ciphertext.len(),
                scan_verdict: attestation.scan_verdict.as_wire().to_owned(),
                risk_flags: attestation.risk_flags.clone(),
                scanner_version: attestation.scanner_version,
                rules_version: attestation.rules_version,
                signer_user_handle: auth.user_handle.clone(),
                signer_device_id: auth.device_id.clone(),
                attestation_signature: attestation.attestation_signature.clone(),
            })
            .map_err(|_| ApiError::internal())?;

        Ok(MediaUploadResponse {
            media_id: media.id,
            uploaded: true,
            attestation_payload,
        })
    }

    /// Downloads ciphertext by bearer capability.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the capability is missing, invalid, expired, or object storage fails.
    pub fn download<S: MediaStore>(
        store: &mut S,
        media_id: &str,
        authorization_header: Option<&str>,
    ) -> Result<MediaDownloadResponse, ApiError> {
        let Some(token) = bearer_capability_token(authorization_header) else {
            return Err(ApiError::unauthorized("Missing media capability token"));
        };
        let media = store
            .find_media_for_capability(media_id, &hash_capability_token(&token))
            .map_err(|_| ApiError::internal())?;
        let Some(media) = media else {
            return Err(ApiError::not_found("Media not found"));
        };
        let ciphertext = store
            .get_ciphertext(&media.storage_bucket, &media.storage_key)
            .map_err(|_| ApiError::internal())?;

        Ok(MediaDownloadResponse {
            headers: ciphertext_response_headers().to_vec(),
            ciphertext,
        })
    }
}

fn find_pending_media_for_upload<S: MediaStore>(
    store: &mut S,
    auth: &AuthenticatedSession,
    media_id: &str,
) -> Result<MediaObjectRecord, ApiError> {
    let media = store
        .find_media_by_id(media_id)
        .map_err(|_| ApiError::internal())?;
    let Some(media) = media else {
        return Err(ApiError::not_found("Media not found"));
    };
    if media.owner_account_id != auth.account_id {
        return Err(ApiError::forbidden("Forbidden"));
    }
    if media.status != MediaStatus::Pending {
        return Err(ApiError::conflict(
            "Media upload is no longer pending",
            None,
        ));
    }

    Ok(media)
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

pub(crate) const fn media_rejection_error(reason: MediaRejectReason) -> ApiError {
    match reason {
        MediaRejectReason::EmptyCiphertextBody => {
            ApiError::bad_request("Ciphertext body is required")
        }
        MediaRejectReason::InvalidDownloadCapability => {
            ApiError::forbidden("Invalid media capability token")
        }
        MediaRejectReason::StaleScannerVersion => {
            ApiError::conflict("Attachment scanner is out of date", None)
        }
        MediaRejectReason::StaleRulesVersion => {
            ApiError::conflict("Attachment scan rules are out of date", None)
        }
        MediaRejectReason::BlockedByClientScan | MediaRejectReason::ClientScanUnscannable => {
            ApiError::unprocessable("Attachment rejected by security scan")
        }
        MediaRejectReason::CiphertextHashMismatch => {
            ApiError::bad_request("Ciphertext hash mismatch")
        }
        MediaRejectReason::InvalidAttestationSignature => {
            ApiError::forbidden("Invalid media attestation signature")
        }
    }
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
        CreatePendingMedia, MarkUploadedVerified, MediaDownloadResponse, MediaObjectRecord,
        MediaService, MediaStatus, MediaStore, MediaUploadInitContext, MediaUploadInitRequest,
        MediaUploadPolicy, MediaUploadRequest,
    };
    use crate::auth_service::{ApiError, ApiStatus, AuthenticatedSession, StoreError};
    use crate::media::{hash_capability_token, MediaScanVerdict, MediaUploadAttestation};
    use std::collections::BTreeMap;

    const ACCOUNT_ID: &str = "acc-1";
    const HANDLE: &str = "@alice:messenger.example.com";
    const DEVICE_ID: &str = "dev-a";
    const MEDIA_ID: &str = "media-1";
    const CAPABILITY_TOKEN: &str = "capability-token-1234567890abcdef";
    const CAPABILITY_HASH: &str =
        "564fd9c631139f10002ff7e2b7da0e77ae6d1ba9ef20ac2cfee819222a673362";
    const IDENTITY_PUBLIC_KEY: &str = "Cc21oHXB+qaBdnL8TkBeWcP/kd5QVfxxf7AB1hlQupk=";
    const ATTESTATION_SIGNATURE: &str =
        "V5mF43nrp3Ho4zaYfANDT7hllq/v2jxBM1OOuNsV6JsVWejAqEIDQidClreXRBuICA23Wl8RGA94hraA7nU6Aw==";

    #[test]
    fn upload_init_creates_pending_media_with_hashed_capability() {
        let mut store = FakeMediaStore::default();
        let request = MediaUploadInitRequest {
            mime_hint: Some("application/octet-stream".to_owned()),
            size_hint: Some(15),
            ttl_sec: Some(60),
        };

        let response = MediaService::upload_init(&mut store, &auth(), &request, &init_context());

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.media_id, MEDIA_ID);
        assert_eq!(body.upload_path, "/api/media/upload/media-1");
        assert_eq!(body.download_path, "/api/media/ciphertext/media-1");
        assert_eq!(body.download_capability, CAPABILITY_TOKEN);
        assert_eq!(
            store
                .created
                .first()
                .map(|created| created.download_capability_hash.as_str()),
            Some(CAPABILITY_HASH)
        );
    }

    #[test]
    fn upload_stores_ciphertext_and_marks_verified() {
        let mut store = FakeMediaStore::with_pending();
        store.identity_public_key = Some(IDENTITY_PUBLIC_KEY.to_owned());
        let request = MediaUploadRequest {
            media_id: MEDIA_ID.to_owned(),
            ciphertext: b"ciphertext-warn".to_vec(),
            attestation: Some(valid_attestation()),
        };

        let response = MediaService::upload(&mut store, &auth(), &request, &policy());

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert!(body.uploaded);
        assert_eq!(body.media_id, MEDIA_ID);
        assert_eq!(
            store
                .ciphertext_objects
                .get("bucket/media/key")
                .map(Vec::as_slice),
            Some(b"ciphertext-warn".as_slice())
        );
        assert_eq!(
            store.verified.first().map(|verified| verified.id.as_str()),
            Some(MEDIA_ID)
        );
    }

    #[test]
    fn upload_rejects_invalid_capability_and_persists_reason() {
        let mut store = FakeMediaStore::with_pending();
        store.identity_public_key = Some(IDENTITY_PUBLIC_KEY.to_owned());
        let mut attestation = valid_attestation();
        attestation.capability_token = "wrong-token".to_owned();
        let request = MediaUploadRequest {
            media_id: MEDIA_ID.to_owned(),
            ciphertext: b"ciphertext-warn".to_vec(),
            attestation: Some(attestation),
        };

        let response = MediaService::upload(&mut store, &auth(), &request, &policy());

        assert_eq!(
            response.err(),
            Some(ApiError::new(
                ApiStatus::Forbidden,
                "Invalid media capability token",
                None
            ))
        );
        assert_eq!(
            store
                .rejections
                .first()
                .map(|rejection| rejection.reason.as_str()),
            Some("invalid_download_capability")
        );
    }

    #[test]
    fn download_requires_capability_and_returns_ciphertext_headers() {
        let mut store = FakeMediaStore::with_pending();
        store.media.insert(
            MEDIA_ID.to_owned(),
            MediaObjectRecord {
                id: MEDIA_ID.to_owned(),
                owner_account_id: ACCOUNT_ID.to_owned(),
                status: MediaStatus::UploadedVerified,
                download_capability_hash: CAPABILITY_HASH.to_owned(),
                storage_bucket: "bucket".to_owned(),
                storage_key: "media/key".to_owned(),
            },
        );
        store
            .ciphertext_objects
            .insert("bucket/media/key".to_owned(), b"ciphertext".to_vec());

        let missing = MediaService::download(&mut store, MEDIA_ID, None);
        assert_eq!(
            missing.err(),
            Some(ApiError::new(
                ApiStatus::Unauthorized,
                "Missing media capability token",
                None
            ))
        );

        let response = MediaService::download(
            &mut store,
            MEDIA_ID,
            Some("Bearer capability-token-1234567890abcdef"),
        );
        assert_download_response(response);
    }

    fn assert_download_response(response: Result<MediaDownloadResponse, ApiError>) {
        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.ciphertext, b"ciphertext".to_vec());
        assert!(body
            .headers
            .contains(&("Content-Type", "application/octet-stream")));
    }

    fn auth() -> AuthenticatedSession {
        AuthenticatedSession {
            account_id: ACCOUNT_ID.to_owned(),
            user_handle: HANDLE.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            session_id: "sess-1".to_owned(),
        }
    }

    fn init_context() -> MediaUploadInitContext {
        MediaUploadInitContext {
            now_ms: 1_700_000_000_000,
            media_id: MEDIA_ID.to_owned(),
            storage_bucket: "bucket".to_owned(),
            storage_key: "media/key".to_owned(),
            capability_token: CAPABILITY_TOKEN.to_owned(),
            origin_server: "messenger.example.com".to_owned(),
        }
    }

    fn policy() -> MediaUploadPolicy {
        MediaUploadPolicy {
            min_scanner_version: 1,
            min_rules_version: 1,
        }
    }

    fn valid_attestation() -> MediaUploadAttestation {
        MediaUploadAttestation {
            capability_token: CAPABILITY_TOKEN.to_owned(),
            ciphertext_sha256: "1423d4e5bc2d4bc05052a8730017fe1430eacea29d957dfb3bda299fa1587064"
                .to_owned(),
            scan_verdict: MediaScanVerdict::Warn,
            risk_flags: vec!["pdf_active_content".to_owned()],
            scanner_version: 1,
            rules_version: 1,
            attestation_signature: ATTESTATION_SIGNATURE.to_owned(),
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakeMediaStore {
        media: BTreeMap<String, MediaObjectRecord>,
        created: Vec<CreatePendingMedia>,
        rejections: Vec<Rejection>,
        identity_public_key: Option<String>,
        ciphertext_objects: BTreeMap<String, Vec<u8>>,
        verified: Vec<MarkUploadedVerified>,
    }

    impl FakeMediaStore {
        fn with_pending() -> Self {
            let mut store = Self::default();
            store.media.insert(
                MEDIA_ID.to_owned(),
                MediaObjectRecord {
                    id: MEDIA_ID.to_owned(),
                    owner_account_id: ACCOUNT_ID.to_owned(),
                    status: MediaStatus::Pending,
                    download_capability_hash: hash_capability_token(CAPABILITY_TOKEN),
                    storage_bucket: "bucket".to_owned(),
                    storage_key: "media/key".to_owned(),
                },
            );
            store
        }
    }

    impl MediaStore for FakeMediaStore {
        fn create_pending_media(
            &mut self,
            input: CreatePendingMedia,
        ) -> Result<MediaObjectRecord, StoreError> {
            self.created.push(input.clone());
            let media = MediaObjectRecord {
                id: MEDIA_ID.to_owned(),
                owner_account_id: input.owner_account_id,
                status: MediaStatus::Pending,
                download_capability_hash: input.download_capability_hash,
                storage_bucket: input.storage_bucket,
                storage_key: input.storage_key,
            };
            self.media.insert(media.id.clone(), media.clone());
            Ok(media)
        }

        fn find_media_by_id(&mut self, id: &str) -> Result<Option<MediaObjectRecord>, StoreError> {
            Ok(self.media.get(id).cloned())
        }

        fn find_media_for_capability(
            &mut self,
            id: &str,
            capability_hash: &str,
        ) -> Result<Option<MediaObjectRecord>, StoreError> {
            Ok(self
                .media
                .get(id)
                .filter(|media| {
                    media.status == MediaStatus::UploadedVerified
                        && media.download_capability_hash == capability_hash
                })
                .cloned())
        }

        fn mark_rejected(&mut self, id: &str, reason: &str) -> Result<(), StoreError> {
            self.rejections.push(Rejection {
                id: id.to_owned(),
                reason: reason.to_owned(),
            });
            Ok(())
        }

        fn identity_public_key(&mut self, _account_id: &str) -> Result<Option<String>, StoreError> {
            Ok(self.identity_public_key.clone())
        }

        fn put_ciphertext(
            &mut self,
            storage_bucket: &str,
            storage_key: &str,
            ciphertext: &[u8],
        ) -> Result<(), StoreError> {
            self.ciphertext_objects.insert(
                format!("{storage_bucket}/{storage_key}"),
                ciphertext.to_vec(),
            );
            Ok(())
        }

        fn mark_uploaded_verified(
            &mut self,
            input: MarkUploadedVerified,
        ) -> Result<MediaObjectRecord, StoreError> {
            self.verified.push(input.clone());
            let Some(media) = self.media.get_mut(&input.id) else {
                return Err(StoreError);
            };
            media.status = MediaStatus::UploadedVerified;
            Ok(media.clone())
        }

        fn get_ciphertext(
            &mut self,
            storage_bucket: &str,
            storage_key: &str,
        ) -> Result<Vec<u8>, StoreError> {
            self.ciphertext_objects
                .get(&format!("{storage_bucket}/{storage_key}"))
                .cloned()
                .ok_or(StoreError)
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct Rejection {
        id: String,
        reason: String,
    }
}
