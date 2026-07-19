//! Federation request signing and ingress contract.

use crate::auth::verify_ed25519;
use crate::hashing::sha256_base64;
use crate::messages::{push_kind_for_job, validate_delivery, DeliveryUnit, MessageError, PushKind};
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt::{Display, Formatter};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

/// Maximum federation deliveries accepted in one ingress request.
pub const MAX_FEDERATION_DELIVERIES: usize = 1_000;

/// Federation request date skew allowance in milliseconds.
pub const FEDERATION_DATE_SKEW_MS: u64 = 5 * 60 * 1_000;

/// Federation key cache TTL in milliseconds.
pub const FEDERATION_KEY_CACHE_MS: u64 = 1_000 * 60 * 30;

/// Default federation request timeout.
pub const FEDERATION_REQUEST_TIMEOUT_MS: u64 = 5_000;

/// Incoming federation auth headers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// Federation headers are canonicalized before signing to avoid transport-specific signature drift.
pub struct FederationHeaders<'a> {
    pub x_mesh_server: &'a str,
    pub x_mesh_key_id: &'a str,
    pub x_mesh_date: &'a str,
    pub x_mesh_signature: &'a str,
    pub x_mesh_body_sha256: &'a str,
}

/// Trusted federation server row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrustedFederationServer<'a> {
    pub domain: &'a str,
    pub key_id: &'a str,
    pub server_sign_pub: &'a str,
    pub trust_state: FederationTrustState,
}

/// Federation server trust state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FederationTrustState {
    Active,
    Blocked,
}

/// Federation receipt status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FederationReceiptStatus {
    Accepted,
    Acked,
    Rejected,
}

impl FederationReceiptStatus {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Acked => "acked",
            Self::Rejected => "rejected",
        }
    }
}

/// Federation delivery route result status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FederationDeliveryStatus {
    Accepted,
    Unavailable,
    Rejected,
}

impl FederationDeliveryStatus {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Unavailable => "unavailable",
            Self::Rejected => "rejected",
        }
    }
}

/// Federation verification result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FederationVerification<'a> {
    Verified {
        server_domain: &'a str,
        key_id: &'a str,
    },
    Unauthorized,
    Blocked,
}

/// Federation verification input.
#[derive(Debug, Clone, Copy)]
pub struct FederationVerificationInput<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub body_raw: &'a str,
    pub headers: FederationHeaders<'a>,
    pub trusted_server: Option<TrustedFederationServer<'a>>,
    pub now_ms: u64,
}

/// Server keys payload contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ServerKeysPayload {
    pub server_name: String,
    pub key_id: String,
    pub public_key: String,
    pub valid_until: String,
    pub algorithm: &'static str,
}

/// Federation contract error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FederationError {
    MissingHeader,
    InvalidDate,
    DeliveryBatchEmpty,
    DeliveryBatchTooLarge,
    InvalidDelivery(MessageError),
}

impl Display for FederationError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingHeader => formatter.write_str("missing federation header"),
            Self::InvalidDate => formatter.write_str("invalid federation date"),
            Self::DeliveryBatchEmpty => formatter.write_str("federation delivery batch is empty"),
            Self::DeliveryBatchTooLarge => {
                formatter.write_str("federation delivery batch is too large")
            }
            Self::InvalidDelivery(error) => {
                write!(formatter, "invalid federation delivery: {error}")
            }
        }
    }
}

impl Error for FederationError {}

#[must_use]
pub fn canonical_federation_string(
    method: &str,
    path: &str,
    x_mesh_date: &str,
    body_raw: &str,
) -> String {
    [
        method.to_ascii_uppercase(),
        path.to_owned(),
        x_mesh_date.to_owned(),
        sha256_base64(body_raw.as_bytes()),
    ]
    .join("\n")
}

#[must_use]
pub fn body_hash_matches(x_mesh_body_sha256: &str, body_raw: &str) -> bool {
    sha256_base64(body_raw.as_bytes()) == x_mesh_body_sha256
}

#[must_use]
pub fn verify_federation_signature(
    method: &str,
    path: &str,
    x_mesh_date: &str,
    body_raw: &str,
    signature: &str,
    remote_public_key: &str,
) -> bool {
    let canonical = canonical_federation_string(method, path, x_mesh_date, body_raw);
    verify_ed25519(&canonical, signature, remote_public_key).unwrap_or(false)
}

/// Verifies federation request headers against a trusted server row.
///
/// # Errors
///
/// Returns an error when required headers are missing or the date is not parseable.
pub fn verify_incoming_federation_request<'a>(
    input: &'a FederationVerificationInput<'a>,
) -> Result<FederationVerification<'a>, FederationError> {
    if input.headers.x_mesh_server.is_empty()
        || input.headers.x_mesh_key_id.is_empty()
        || input.headers.x_mesh_date.is_empty()
        || input.headers.x_mesh_signature.is_empty()
        || input.headers.x_mesh_body_sha256.is_empty()
    {
        return Err(FederationError::MissingHeader);
    }

    if !body_hash_matches(input.headers.x_mesh_body_sha256, input.body_raw) {
        return Ok(FederationVerification::Unauthorized);
    }

    if !federation_date_fresh(input.headers.x_mesh_date, input.now_ms)? {
        return Ok(FederationVerification::Unauthorized);
    }

    let Some(trusted) = input.trusted_server else {
        return Ok(FederationVerification::Unauthorized);
    };
    if trusted.trust_state == FederationTrustState::Blocked {
        return Ok(FederationVerification::Blocked);
    }
    if trusted.key_id != input.headers.x_mesh_key_id
        || trusted.domain != input.headers.x_mesh_server
    {
        return Ok(FederationVerification::Unauthorized);
    }
    if !verify_federation_signature(
        input.method,
        input.path,
        input.headers.x_mesh_date,
        input.body_raw,
        input.headers.x_mesh_signature,
        trusted.server_sign_pub,
    ) {
        return Ok(FederationVerification::Unauthorized);
    }

    Ok(FederationVerification::Verified {
        server_domain: trusted.domain,
        key_id: trusted.key_id,
    })
}

/// Validates federation delivery batch bounds.
///
/// # Errors
///
/// Returns an error when the batch is empty, too large, or contains an invalid delivery envelope.
pub fn validate_federation_deliveries(deliveries: &[DeliveryUnit]) -> Result<(), FederationError> {
    if deliveries.is_empty() {
        return Err(FederationError::DeliveryBatchEmpty);
    }

    if deliveries.len() > MAX_FEDERATION_DELIVERIES {
        return Err(FederationError::DeliveryBatchTooLarge);
    }

    for delivery in deliveries {
        validate_delivery(delivery).map_err(FederationError::InvalidDelivery)?;
    }

    Ok(())
}

#[must_use]
pub const fn delivery_status(
    account_exists: bool,
    target_device_count: usize,
) -> FederationDeliveryStatus {
    if account_exists && target_device_count > 0 {
        FederationDeliveryStatus::Accepted
    } else {
        FederationDeliveryStatus::Unavailable
    }
}

#[must_use]
pub const fn receipt_for_delivery_status(
    status: FederationDeliveryStatus,
) -> FederationReceiptStatus {
    match status {
        FederationDeliveryStatus::Accepted => FederationReceiptStatus::Accepted,
        FederationDeliveryStatus::Unavailable | FederationDeliveryStatus::Rejected => {
            FederationReceiptStatus::Rejected
        }
    }
}

#[must_use]
pub const fn federation_push_kind(
    allowed_fast_notify: bool,
    push_kind: Option<PushKind>,
) -> Option<PushKind> {
    push_kind_for_job(allowed_fast_notify, push_kind)
}

#[must_use]
pub fn federation_base_url(domain: &str) -> String {
    format!("https://{domain}")
}

#[must_use]
pub const fn federation_auth_status(result: FederationVerification<'_>) -> u16 {
    match result {
        FederationVerification::Verified { .. } => 200,
        FederationVerification::Unauthorized => 401,
        FederationVerification::Blocked => 403,
    }
}

fn federation_date_fresh(x_mesh_date: &str, now_ms: u64) -> Result<bool, FederationError> {
    let date_ms = parse_epoch_ms(x_mesh_date)?;
    Ok(i128::from(now_ms).abs_diff(date_ms) <= u128::from(FEDERATION_DATE_SKEW_MS))
}

fn parse_epoch_ms(value: &str) -> Result<i128, FederationError> {
    let parsed =
        OffsetDateTime::parse(value, &Rfc3339).map_err(|_| FederationError::InvalidDate)?;
    Ok(parsed.unix_timestamp_nanos() / 1_000_000)
}

#[cfg(test)]
mod tests {
    use super::{
        body_hash_matches, canonical_federation_string, delivery_status, federation_auth_status,
        federation_base_url, federation_push_kind, receipt_for_delivery_status,
        validate_federation_deliveries, verify_federation_signature,
        verify_incoming_federation_request, FederationDeliveryStatus, FederationHeaders,
        FederationReceiptStatus, FederationTrustState, FederationVerification,
        FederationVerificationInput, TrustedFederationServer,
    };
    use crate::messages::{DeliveryUnit, PushKind};

    const PUBLIC_KEY: &str = "tTR6QJyD4EwWjnsRFhWC+EfXNSkyax72lhNxPU8yrPc=";
    const BODY_RAW: &str = r#"{"deliveries":[]}"#;
    const BODY_HASH: &str = "cmMWKqmB5Y6wuP1LoFihsX/2IsHoeEgguOwfQH6b04Q=";
    const DATE: &str = "2026-02-26T12:00:00.000Z";
    const SIGNATURE: &str =
        "4Kj+7wdgDhDQTZjHMA0vDdkBJZH8Tbw7ADDbLwxK1tE6d78i55+ePuqV7Ns0WAySkAaAdY0bdprRumTu0lP6AQ==";

    #[test]
    fn builds_canonical_federation_string_and_body_hash() {
        assert_eq!(
            canonical_federation_string("post", "/federation/test", DATE, BODY_RAW),
            concat!(
                "POST\n/federation/test\n2026-02-26T12:00:00.000Z\n",
                "cmMWKqmB5Y6wuP1LoFihsX/2IsHoeEgguOwfQH6b04Q="
            )
        );
        assert!(body_hash_matches(BODY_HASH, BODY_RAW));
        assert!(!body_hash_matches(BODY_HASH, "{}"));
    }

    #[test]
    fn verifies_federation_signature_vector() {
        assert!(verify_federation_signature(
            "POST",
            "/federation/test",
            DATE,
            BODY_RAW,
            SIGNATURE,
            PUBLIC_KEY
        ));
        assert!(!verify_federation_signature(
            "POST",
            "/federation/test",
            DATE,
            "{}",
            SIGNATURE,
            PUBLIC_KEY
        ));
    }

    #[test]
    fn verifies_incoming_request_against_trusted_server() {
        let input = FederationVerificationInput {
            method: "POST",
            path: "/federation/test",
            body_raw: BODY_RAW,
            headers: headers(),
            trusted_server: Some(trusted(FederationTrustState::Active)),
            now_ms: 1_772_107_200_000,
        };

        assert_eq!(
            verify_incoming_federation_request(&input),
            Ok(FederationVerification::Verified {
                server_domain: "trusted.example",
                key_id: "ed25519:trusted",
            })
        );
    }

    #[test]
    fn rejects_blocked_unknown_or_bad_key_federation_server() {
        let mut input = FederationVerificationInput {
            method: "POST",
            path: "/federation/test",
            body_raw: BODY_RAW,
            headers: headers(),
            trusted_server: None,
            now_ms: 1_772_107_200_000,
        };
        assert_eq!(
            verify_incoming_federation_request(&input),
            Ok(FederationVerification::Unauthorized)
        );

        input.trusted_server = Some(trusted(FederationTrustState::Blocked));
        assert_eq!(
            verify_incoming_federation_request(&input),
            Ok(FederationVerification::Blocked)
        );

        input.trusted_server = Some(TrustedFederationServer {
            key_id: "ed25519:other",
            ..trusted(FederationTrustState::Active)
        });
        assert_eq!(
            verify_incoming_federation_request(&input),
            Ok(FederationVerification::Unauthorized)
        );
    }

    #[test]
    fn validates_delivery_batch_and_receipts() {
        assert_eq!(validate_federation_deliveries(&[delivery()]), Ok(()));
        assert_eq!(delivery_status(true, 1), FederationDeliveryStatus::Accepted);
        assert_eq!(
            delivery_status(false, 1),
            FederationDeliveryStatus::Unavailable
        );
        assert_eq!(
            receipt_for_delivery_status(FederationDeliveryStatus::Accepted),
            FederationReceiptStatus::Accepted
        );
        assert_eq!(
            receipt_for_delivery_status(FederationDeliveryStatus::Unavailable),
            FederationReceiptStatus::Rejected
        );
    }

    #[test]
    fn keeps_call_push_kind_private_for_federation() {
        assert_eq!(federation_push_kind(false, Some(PushKind::Message)), None);
        assert_eq!(federation_push_kind(true, Some(PushKind::Call)), None);
        assert_eq!(
            federation_push_kind(true, Some(PushKind::Message)),
            Some(PushKind::Message)
        );
    }

    #[test]
    fn maps_base_url_and_auth_status_codes() {
        assert_eq!(
            federation_base_url("domain-a.example"),
            "https://domain-a.example"
        );
        assert_eq!(
            federation_auth_status(FederationVerification::Unauthorized),
            401
        );
        assert_eq!(federation_auth_status(FederationVerification::Blocked), 403);
    }

    fn headers() -> FederationHeaders<'static> {
        FederationHeaders {
            x_mesh_server: "trusted.example",
            x_mesh_key_id: "ed25519:trusted",
            x_mesh_date: DATE,
            x_mesh_signature: SIGNATURE,
            x_mesh_body_sha256: BODY_HASH,
        }
    }

    fn trusted(trust_state: FederationTrustState) -> TrustedFederationServer<'static> {
        TrustedFederationServer {
            domain: "trusted.example",
            key_id: "ed25519:trusted",
            server_sign_pub: PUBLIC_KEY,
            trust_state,
        }
    }

    fn delivery() -> DeliveryUnit {
        DeliveryUnit {
            wire_version: 2,
            delivery_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            to_server: "domain-b.example".to_owned(),
            to_user: "@bob:domain-b.example".to_owned(),
            to_device_id: "dev-b".to_owned(),
            message_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            timestamp: "2026-03-01T00:00:00.000Z".to_owned(),
            ttl_sec: 600,
            ciphertext_blob: "ciphertext".to_owned(),
            push_kind: None,
            wakeup_class: None,
        }
    }
}
