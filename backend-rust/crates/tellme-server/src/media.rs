//! Secure media upload/download contract.
//!
//! Media objects store ciphertext only. Download capabilities are bearer access tokens, not file
//! decryption keys.

use crate::auth::{normalize_handle, verify_ed25519};
use crate::hashing::sha256_hex;
use std::collections::BTreeSet;
use std::error::Error;
use std::fmt::{Display, Formatter};

/// Default max upload size from the current route.
pub const DEFAULT_MAX_FILE_SIZE_BYTES: u64 = 10_485_760;

/// Default media object TTL for upload init.
pub const DEFAULT_MEDIA_TTL_SEC: u64 = 60 * 60 * 24 * 7;

/// Secure media attestation protocol prefix.
pub const MEDIA_UPLOAD_ATTESTATION_PREFIX: &str = "media-upload-v1";

/// Media scan verdict accepted from client-side attachment scanning.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaScanVerdict {
    Clean,
    Warn,
    Blocked,
    Unscannable,
}

impl MediaScanVerdict {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Clean => "clean",
            Self::Warn => "warn",
            Self::Blocked => "blocked",
            Self::Unscannable => "unscannable",
        }
    }

    #[must_use]
    pub const fn is_accepted(self) -> bool {
        matches!(self, Self::Clean | Self::Warn)
    }
}

/// Media upload attestation supplied through upload headers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaUploadAttestation {
    pub capability_token: String,
    pub ciphertext_sha256: String,
    pub scan_verdict: MediaScanVerdict,
    pub risk_flags: Vec<String>,
    pub scanner_version: u64,
    pub rules_version: u64,
    pub attestation_signature: String,
}

/// Input for building the canonical attestation payload.
#[derive(Debug, Clone, Copy)]
pub struct MediaAttestationPayloadInput<'a> {
    pub media_id: &'a str,
    pub user_handle: &'a str,
    pub device_id: &'a str,
    pub capability_token: &'a str,
    pub ciphertext_sha256: &'a str,
    pub ciphertext_size: usize,
    pub scan_verdict: MediaScanVerdict,
    pub risk_flags: &'a [String],
    pub scanner_version: u64,
    pub rules_version: u64,
}

/// Input for validating upload security before storing ciphertext.
#[derive(Debug, Clone, Copy)]
pub struct MediaUploadValidationInput<'a> {
    pub media_id: &'a str,
    pub user_handle: &'a str,
    pub device_id: &'a str,
    pub expected_capability_hash: &'a str,
    pub ciphertext: &'a [u8],
    pub attestation: &'a MediaUploadAttestation,
    pub min_scanner_version: u64,
    pub min_rules_version: u64,
    pub identity_public_key: &'a str,
}

/// API paths returned by upload init.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaPaths {
    pub upload_path: String,
    pub download_path: String,
}

/// Media rejection reason persisted by the current route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaRejectReason {
    EmptyCiphertextBody,
    InvalidDownloadCapability,
    StaleScannerVersion,
    StaleRulesVersion,
    BlockedByClientScan,
    ClientScanUnscannable,
    CiphertextHashMismatch,
    InvalidAttestationSignature,
}

impl MediaRejectReason {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::EmptyCiphertextBody => "empty_ciphertext_body",
            Self::InvalidDownloadCapability => "invalid_download_capability",
            Self::StaleScannerVersion => "stale_scanner_version",
            Self::StaleRulesVersion => "stale_rules_version",
            Self::BlockedByClientScan => "blocked_by_client_scan",
            Self::ClientScanUnscannable => "client_scan_unscannable",
            Self::CiphertextHashMismatch => "ciphertext_hash_mismatch",
            Self::InvalidAttestationSignature => "invalid_attestation_signature",
        }
    }
}

/// Media contract error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaError {
    InvalidVerdict,
    Rejected(MediaRejectReason),
}

impl Display for MediaError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidVerdict => formatter.write_str("invalid media scan verdict"),
            Self::Rejected(reason) => write!(formatter, "media rejected: {}", reason.as_wire()),
        }
    }
}

impl Error for MediaError {}

/// Parses a media scan verdict from wire text.
///
/// # Errors
///
/// Returns an error when the verdict is not one of `clean`, `warn`, `blocked`, or `unscannable`.
pub fn parse_media_scan_verdict(value: &str) -> Result<MediaScanVerdict, MediaError> {
    match value.trim().to_ascii_lowercase().as_str() {
        "clean" => Ok(MediaScanVerdict::Clean),
        "warn" => Ok(MediaScanVerdict::Warn),
        "blocked" => Ok(MediaScanVerdict::Blocked),
        "unscannable" => Ok(MediaScanVerdict::Unscannable),
        _ => Err(MediaError::InvalidVerdict),
    }
}

#[must_use]
pub fn canonicalize_risk_flags(flags: &[String]) -> Vec<String> {
    flags
        .iter()
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

#[must_use]
pub fn hash_capability_token(token: &str) -> String {
    sha256_hex(token.as_bytes())
}

#[must_use]
pub fn verify_capability_token_hash(expected_hash: Option<&str>, token: &str) -> bool {
    let Some(expected) = expected_hash else {
        return false;
    };
    if expected.is_empty() || token.trim().is_empty() {
        return false;
    }

    constant_time_eq(
        expected.as_bytes(),
        hash_capability_token(token.trim()).as_bytes(),
    )
}

#[must_use]
pub fn build_media_upload_attestation_payload(input: &MediaAttestationPayloadInput<'_>) -> String {
    let risk_flags = canonicalize_risk_flags(input.risk_flags).join(",");
    let capability_hash = hash_capability_token(input.capability_token.trim());

    [
        MEDIA_UPLOAD_ATTESTATION_PREFIX.to_owned(),
        input.media_id.to_owned(),
        normalize_handle(input.user_handle),
        input.device_id.trim().to_owned(),
        capability_hash,
        input.ciphertext_sha256.trim().to_ascii_lowercase(),
        input.ciphertext_size.to_string(),
        input.scan_verdict.as_wire().to_owned(),
        risk_flags,
        input.scanner_version.to_string(),
        input.rules_version.to_string(),
    ]
    .join("|")
}

#[must_use]
pub fn verify_media_upload_attestation(
    input: &MediaAttestationPayloadInput<'_>,
    attestation_signature: &str,
    identity_public_key: &str,
) -> bool {
    let payload = build_media_upload_attestation_payload(input);
    verify_ed25519(&payload, attestation_signature, identity_public_key).unwrap_or(false)
}

/// Validates upload security before ciphertext is accepted for storage.
///
/// # Errors
///
/// Returns a rejection reason matching the current TypeScript route.
pub fn validate_media_upload(input: &MediaUploadValidationInput<'_>) -> Result<String, MediaError> {
    if input.ciphertext.is_empty() {
        return Err(MediaError::Rejected(MediaRejectReason::EmptyCiphertextBody));
    }

    if !verify_capability_token_hash(
        Some(input.expected_capability_hash),
        &input.attestation.capability_token,
    ) {
        return Err(MediaError::Rejected(
            MediaRejectReason::InvalidDownloadCapability,
        ));
    }

    if input.attestation.scanner_version < input.min_scanner_version {
        return Err(MediaError::Rejected(MediaRejectReason::StaleScannerVersion));
    }

    if input.attestation.rules_version < input.min_rules_version {
        return Err(MediaError::Rejected(MediaRejectReason::StaleRulesVersion));
    }

    if !input.attestation.scan_verdict.is_accepted() {
        return Err(MediaError::Rejected(match input.attestation.scan_verdict {
            MediaScanVerdict::Blocked => MediaRejectReason::BlockedByClientScan,
            _ => MediaRejectReason::ClientScanUnscannable,
        }));
    }

    let computed_hash = sha256_hex(input.ciphertext);
    if computed_hash != input.attestation.ciphertext_sha256 {
        return Err(MediaError::Rejected(
            MediaRejectReason::CiphertextHashMismatch,
        ));
    }

    let payload_input = MediaAttestationPayloadInput {
        media_id: input.media_id,
        user_handle: input.user_handle,
        device_id: input.device_id,
        capability_token: &input.attestation.capability_token,
        ciphertext_sha256: &computed_hash,
        ciphertext_size: input.ciphertext.len(),
        scan_verdict: input.attestation.scan_verdict,
        risk_flags: &input.attestation.risk_flags,
        scanner_version: input.attestation.scanner_version,
        rules_version: input.attestation.rules_version,
    };

    if !verify_media_upload_attestation(
        &payload_input,
        &input.attestation.attestation_signature,
        input.identity_public_key,
    ) {
        return Err(MediaError::Rejected(
            MediaRejectReason::InvalidAttestationSignature,
        ));
    }

    Ok(build_media_upload_attestation_payload(&payload_input))
}

#[must_use]
pub fn bearer_capability_token(authorization_header: Option<&str>) -> Option<String> {
    let token = authorization_header?.strip_prefix("Bearer ")?.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_owned())
    }
}

#[must_use]
pub fn media_paths(media_id: &str) -> MediaPaths {
    MediaPaths {
        upload_path: format!("/api/media/upload/{media_id}"),
        download_path: format!("/api/media/ciphertext/{media_id}"),
    }
}

#[must_use]
pub const fn ciphertext_response_headers() -> [(&'static str, &'static str); 4] {
    [
        ("Content-Type", "application/octet-stream"),
        ("Cache-Control", "no-store"),
        ("Pragma", "no-cache"),
        ("X-Content-Type-Options", "nosniff"),
    ]
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }

    let mut diff = 0_u8;
    for (left_byte, right_byte) in left.iter().zip(right.iter()) {
        diff |= left_byte ^ right_byte;
    }

    diff == 0
}

#[cfg(test)]
mod tests {
    use super::{
        bearer_capability_token, build_media_upload_attestation_payload, canonicalize_risk_flags,
        ciphertext_response_headers, hash_capability_token, media_paths, parse_media_scan_verdict,
        validate_media_upload, verify_capability_token_hash, verify_media_upload_attestation,
        MediaAttestationPayloadInput, MediaError, MediaRejectReason, MediaScanVerdict,
        MediaUploadAttestation, MediaUploadValidationInput,
    };

    const IDENTITY_PUBLIC_KEY: &str = "Cc21oHXB+qaBdnL8TkBeWcP/kd5QVfxxf7AB1hlQupk=";
    const ATTESTATION_SIGNATURE: &str =
        "V5mF43nrp3Ho4zaYfANDT7hllq/v2jxBM1OOuNsV6JsVWejAqEIDQidClreXRBuICA23Wl8RGA94hraA7nU6Aw==";
    const CAPABILITY_HASH: &str =
        "564fd9c631139f10002ff7e2b7da0e77ae6d1ba9ef20ac2cfee819222a673362";
    const CIPHERTEXT_HASH: &str =
        "1423d4e5bc2d4bc05052a8730017fe1430eacea29d957dfb3bda299fa1587064";
    const ATTESTATION_PAYLOAD: &str = concat!(
        "media-upload-v1|media-1|@alice:messenger.example.com|dev-a|",
        "564fd9c631139f10002ff7e2b7da0e77ae6d1ba9ef20ac2cfee819222a673362|",
        "1423d4e5bc2d4bc05052a8730017fe1430eacea29d957dfb3bda299fa1587064|",
        "15|warn|pdf_active_content|1|1"
    );

    #[test]
    fn parses_verdicts_and_canonicalizes_risk_flags() {
        assert_eq!(
            parse_media_scan_verdict(" WARN "),
            Ok(MediaScanVerdict::Warn)
        );
        assert!(parse_media_scan_verdict("unknown").is_err());
        assert_eq!(
            canonicalize_risk_flags(&[
                " pdf_active_content ".to_owned(),
                "OOXML_MACRO_PAYLOAD".to_owned(),
                "pdf_active_content".to_owned(),
                String::new(),
            ]),
            vec![
                "ooxml_macro_payload".to_owned(),
                "pdf_active_content".to_owned()
            ]
        );
    }

    #[test]
    fn hashes_and_verifies_capability_token() {
        assert_eq!(
            hash_capability_token("capability-token-1234567890abcdef"),
            CAPABILITY_HASH
        );
        assert!(verify_capability_token_hash(
            Some(CAPABILITY_HASH),
            " capability-token-1234567890abcdef "
        ));
        assert!(!verify_capability_token_hash(
            Some(CAPABILITY_HASH),
            "wrong-token"
        ));
        assert!(!verify_capability_token_hash(
            None,
            "capability-token-1234567890abcdef"
        ));
    }

    #[test]
    fn builds_and_verifies_attestation_payload() {
        let risk_flags = vec!["pdf_active_content".to_owned()];
        let input = payload_input(&risk_flags);

        assert_eq!(
            build_media_upload_attestation_payload(&input),
            ATTESTATION_PAYLOAD
        );
        assert!(verify_media_upload_attestation(
            &input,
            ATTESTATION_SIGNATURE,
            IDENTITY_PUBLIC_KEY
        ));
    }

    #[test]
    fn validates_secure_media_upload() {
        let attestation = valid_attestation();
        let validation = MediaUploadValidationInput {
            media_id: "media-1",
            user_handle: "@alice:messenger.example.com",
            device_id: "dev-a",
            expected_capability_hash: CAPABILITY_HASH,
            ciphertext: b"ciphertext-warn",
            attestation: &attestation,
            min_scanner_version: 1,
            min_rules_version: 1,
            identity_public_key: IDENTITY_PUBLIC_KEY,
        };

        assert_eq!(
            validate_media_upload(&validation).as_deref(),
            Ok(ATTESTATION_PAYLOAD)
        );
    }

    #[test]
    fn rejects_blocked_stale_and_mismatched_uploads() {
        let mut attestation = valid_attestation();
        attestation.scan_verdict = MediaScanVerdict::Blocked;
        assert_eq!(
            validate_media_upload(&validation_input(&attestation)).err(),
            Some(MediaError::Rejected(MediaRejectReason::BlockedByClientScan))
        );

        let mut attestation = valid_attestation();
        attestation.scanner_version = 0;
        assert_eq!(
            validate_media_upload(&validation_input(&attestation)).err(),
            Some(MediaError::Rejected(MediaRejectReason::StaleScannerVersion))
        );

        let mut attestation = valid_attestation();
        attestation.ciphertext_sha256 = "0".repeat(64);
        assert_eq!(
            validate_media_upload(&validation_input(&attestation)).err(),
            Some(MediaError::Rejected(
                MediaRejectReason::CiphertextHashMismatch
            ))
        );
    }

    #[test]
    fn extracts_download_bearer_and_headers() {
        assert_eq!(
            bearer_capability_token(Some("Bearer capability-token-1234567890abcdef")).as_deref(),
            Some("capability-token-1234567890abcdef")
        );
        assert_eq!(bearer_capability_token(Some("bearer capability")), None);
        assert_eq!(bearer_capability_token(Some("Bearer   ")), None);

        let paths = media_paths("media-1");
        assert_eq!(paths.upload_path, "/api/media/upload/media-1");
        assert_eq!(paths.download_path, "/api/media/ciphertext/media-1");
        assert!(ciphertext_response_headers().contains(&("Cache-Control", "no-store")));
        assert!(ciphertext_response_headers().contains(&("X-Content-Type-Options", "nosniff")));
    }

    fn payload_input(risk_flags: &[String]) -> MediaAttestationPayloadInput<'_> {
        MediaAttestationPayloadInput {
            media_id: "media-1",
            user_handle: "@alice:messenger.example.com",
            device_id: "dev-a",
            capability_token: "capability-token-1234567890abcdef",
            ciphertext_sha256: CIPHERTEXT_HASH,
            ciphertext_size: 15,
            scan_verdict: MediaScanVerdict::Warn,
            risk_flags,
            scanner_version: 1,
            rules_version: 1,
        }
    }

    fn valid_attestation() -> MediaUploadAttestation {
        MediaUploadAttestation {
            capability_token: "capability-token-1234567890abcdef".to_owned(),
            ciphertext_sha256: CIPHERTEXT_HASH.to_owned(),
            scan_verdict: MediaScanVerdict::Warn,
            risk_flags: vec!["pdf_active_content".to_owned()],
            scanner_version: 1,
            rules_version: 1,
            attestation_signature: ATTESTATION_SIGNATURE.to_owned(),
        }
    }

    fn validation_input(attestation: &MediaUploadAttestation) -> MediaUploadValidationInput<'_> {
        MediaUploadValidationInput {
            media_id: "media-1",
            user_handle: "@alice:messenger.example.com",
            device_id: "dev-a",
            expected_capability_hash: CAPABILITY_HASH,
            ciphertext: b"ciphertext-warn",
            attestation,
            min_scanner_version: 1,
            min_rules_version: 1,
            identity_public_key: IDENTITY_PUBLIC_KEY,
        }
    }
}
