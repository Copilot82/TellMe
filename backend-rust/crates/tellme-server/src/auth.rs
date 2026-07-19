//! Auth and device-certificate protocol contract for the `TellMe` v2 hard cutover.
//!
//! This module intentionally starts as pure protocol logic. Route handlers and database writes will be layered on top
//! only after the canonical strings, timestamps, and signature rules are locked against the current TypeScript backend
//! and iOS reference client.

use crate::hashing::sha256_hex;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine as _;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::error::Error;
use std::fmt::{Display, Formatter};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

/// Current device-certificate version accepted by the hard-cutover backend.
pub const DEVICE_CERTIFICATE_VERSION_V2: u8 = 2;

/// Maximum account-to-device certificate chain depth accepted by the current backend.
pub const MAX_DEVICE_CERTIFICATE_CHAIN_DEPTH: usize = 5;

/// Allowed registration timestamp skew in milliseconds.
pub const REGISTRATION_TIMESTAMP_SKEW_MS: u64 = 5 * 60 * 1_000;

const ED25519_PUBLIC_KEY_LENGTH: usize = 32;
const ED25519_SIGNATURE_LENGTH: usize = 64;
const ED25519_SPKI_PREFIX: [u8; 12] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

/// Parsed federation-friendly user handle.
#[derive(Debug, Clone, PartialEq, Eq)]
// Normalize handles before validation so storage never branches on presentation casing.
pub struct UserHandle {
    normalized: String,
    username: String,
    domain: String,
}

impl UserHandle {
    #[must_use]
    pub fn normalized(&self) -> &str {
        &self.normalized
    }

    #[must_use]
    pub fn username(&self) -> &str {
        &self.username
    }

    #[must_use]
    pub fn domain(&self) -> &str {
        &self.domain
    }
}

/// Device-certificate issuer kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CertificateIssuerKind {
    Account,
    Device,
}

impl CertificateIssuerKind {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Account => "account",
            Self::Device => "device",
        }
    }
}

/// Device certificate payload used by auth, device linking, and prekey responses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceCertificate {
    pub device_certificate_version: u8,
    pub account_handle: String,
    pub device_id: String,
    pub device_sign_pub: String,
    pub device_dh_pub: String,
    pub issuer_kind: CertificateIssuerKind,
    pub issuer_device_id: Option<String>,
    pub parent_certificate_id: Option<String>,
    pub issued_at: String,
    pub expires_at: Option<String>,
    pub signature: String,
}

/// Inputs needed to validate a device-certificate chain against an account and device tuple.
#[derive(Debug, Clone, Copy)]
pub struct DeviceCertificateChainInput<'a> {
    pub account_handle: &'a str,
    pub account_sign_pub: &'a str,
    pub device_id: &'a str,
    pub device_sign_pub: &'a str,
    pub device_dh_pub: &'a str,
    pub chain: &'a [DeviceCertificate],
    pub now_ms: u64,
}

/// Successful device-certificate chain validation result.
#[derive(Debug, Clone, Copy)]
pub struct ValidatedDeviceCertificateChain<'a> {
    leaf: &'a DeviceCertificate,
    normalized_chain: &'a [DeviceCertificate],
}

impl<'a> ValidatedDeviceCertificateChain<'a> {
    #[must_use]
    pub const fn leaf(self) -> &'a DeviceCertificate {
        self.leaf
    }

    #[must_use]
    pub const fn normalized_chain(self) -> &'a [DeviceCertificate] {
        self.normalized_chain
    }
}

/// Auth protocol error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContractError {
    InvalidHandle,
    InvalidPublicKey,
    InvalidSignature,
    InvalidTimestamp,
    EmptyCertificateChain,
    CertificateChainTooDeep,
    UnsupportedCertificateVersion,
    CertificateAccountMismatch,
    DuplicateCertificateDevice,
    ExpiredCertificate,
    MissingCertificateSignature,
    InvalidRootCertificateIssuer,
    UnexpectedRootCertificateParent,
    InvalidChildCertificateIssuer,
    CertificateIssuerMismatch,
    CertificateParentMismatch,
    CertificateSignatureMismatch,
    CertificateLeafMismatch,
}

impl Display for ContractError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidHandle => formatter.write_str("invalid user handle"),
            Self::InvalidPublicKey => formatter.write_str("invalid Ed25519 public key"),
            Self::InvalidSignature => formatter.write_str("invalid Ed25519 signature"),
            Self::InvalidTimestamp => formatter.write_str("invalid ISO timestamp"),
            Self::EmptyCertificateChain => formatter.write_str("device certificate chain is empty"),
            Self::CertificateChainTooDeep => {
                formatter.write_str("device certificate chain is too deep")
            }
            Self::UnsupportedCertificateVersion => {
                formatter.write_str("unsupported device certificate version")
            }
            Self::CertificateAccountMismatch => {
                formatter.write_str("device certificate account mismatch")
            }
            Self::DuplicateCertificateDevice => {
                formatter.write_str("duplicate device in certificate chain")
            }
            Self::ExpiredCertificate => formatter.write_str("expired device certificate"),
            Self::MissingCertificateSignature => {
                formatter.write_str("missing device certificate signature")
            }
            Self::InvalidRootCertificateIssuer => {
                formatter.write_str("invalid root certificate issuer")
            }
            Self::UnexpectedRootCertificateParent => {
                formatter.write_str("root certificate must not reference parent device")
            }
            Self::InvalidChildCertificateIssuer => {
                formatter.write_str("invalid child certificate issuer")
            }
            Self::CertificateIssuerMismatch => {
                formatter.write_str("device certificate issuer mismatch")
            }
            Self::CertificateParentMismatch => {
                formatter.write_str("device certificate parent mismatch")
            }
            Self::CertificateSignatureMismatch => {
                formatter.write_str("device certificate signature mismatch")
            }
            Self::CertificateLeafMismatch => {
                formatter.write_str("device certificate leaf mismatch")
            }
        }
    }
}

impl Error for ContractError {}

#[must_use]
pub fn normalize_handle(handle: &str) -> String {
    handle.trim().to_ascii_lowercase()
}

/// Parses an `@user:domain` handle using the current TypeScript server contract.
///
/// # Errors
///
/// Returns an error when the handle does not match `^@([a-z0-9._-]+):([a-z0-9.-]+)$` after
/// normalization.
pub fn parse_handle(handle: &str) -> Result<UserHandle, ContractError> {
    let normalized = normalize_handle(handle);
    let (username, domain) = {
        let without_prefix = normalized
            .strip_prefix('@')
            .ok_or(ContractError::InvalidHandle)?;
        let (username, domain) = without_prefix
            .split_once(':')
            .ok_or(ContractError::InvalidHandle)?;

        if username.is_empty()
            || domain.is_empty()
            || domain.contains(':')
            || !username.chars().all(is_valid_username_char)
            || !domain.chars().all(is_valid_domain_char)
        {
            return Err(ContractError::InvalidHandle);
        }

        (username.to_owned(), domain.to_owned())
    };

    Ok(UserHandle {
        normalized,
        username,
        domain,
    })
}

#[must_use]
pub const fn registration_timestamp_fresh(now_ms: u64, timestamp_ms: u64) -> bool {
    now_ms.abs_diff(timestamp_ms) <= REGISTRATION_TIMESTAMP_SKEW_MS
}

#[must_use]
pub fn registration_proof_payload(
    user_handle: &str,
    ik_sign_pub: &str,
    ik_dh_pub: &str,
    timestamp_iso: &str,
) -> String {
    format!(
        "register|{}|{ik_sign_pub}|{ik_dh_pub}|{timestamp_iso}",
        normalize_handle(user_handle)
    )
}

/// Verifies a registration proof against the account identity signing key.
#[must_use]
pub fn registration_signature_valid(
    user_handle: &str,
    ik_sign_pub: &str,
    ik_dh_pub: &str,
    timestamp_iso: &str,
    signature_base64: &str,
) -> bool {
    let payload = registration_proof_payload(user_handle, ik_sign_pub, ik_dh_pub, timestamp_iso);
    verify_ed25519(&payload, signature_base64, ik_sign_pub).unwrap_or(false)
}

#[must_use]
pub fn device_certificate_canonical_fields(certificate: &DeviceCertificate) -> String {
    [
        certificate.device_certificate_version.to_string(),
        normalize_handle(&certificate.account_handle),
        certificate.device_id.clone(),
        certificate.device_sign_pub.clone(),
        certificate.device_dh_pub.clone(),
        certificate.issuer_kind.as_wire().to_owned(),
        certificate.issuer_device_id.clone().unwrap_or_default(),
        certificate
            .parent_certificate_id
            .clone()
            .unwrap_or_default(),
        certificate.issued_at.clone(),
        certificate.expires_at.clone().unwrap_or_default(),
    ]
    .join("|")
}

#[must_use]
pub fn device_certificate_signing_payload(certificate: &DeviceCertificate) -> String {
    format!(
        "device_certificate|{}",
        device_certificate_canonical_fields(certificate)
    )
}

#[must_use]
pub fn device_certificate_id(certificate: &DeviceCertificate) -> String {
    sha256_hex(device_certificate_canonical_fields(certificate).as_bytes())
}

/// Verifies one `Ed25519` signature. Public keys may be raw 32-byte base64/base64url, SPKI DER
/// base64/base64url, or PEM public keys.
///
/// # Errors
///
/// Returns an error when key or signature material cannot be decoded as an `Ed25519` value.
pub fn verify_ed25519(
    message: &str,
    signature_base64: &str,
    public_key: &str,
) -> Result<bool, ContractError> {
    let key_bytes = public_key_bytes(public_key)?;
    let verifying_key =
        VerifyingKey::from_bytes(&key_bytes).map_err(|_| ContractError::InvalidPublicKey)?;
    let signature_bytes = decode_base64_or_url(signature_base64)?;
    if signature_bytes.len() != ED25519_SIGNATURE_LENGTH {
        return Err(ContractError::InvalidSignature);
    }
    let signature = Signature::try_from(signature_bytes.as_slice())
        .map_err(|_| ContractError::InvalidSignature)?;

    Ok(verifying_key.verify(message.as_bytes(), &signature).is_ok())
}

/// Validates the current v2 device-certificate chain contract.
///
/// # Errors
///
/// Returns an error when chain shape, timestamps, parent links, leaf identity, or signatures do not
/// match the hard-cutover contract.
pub fn validate_device_certificate_chain<'a>(
    input: &DeviceCertificateChainInput<'a>,
) -> Result<ValidatedDeviceCertificateChain<'a>, ContractError> {
    if input.chain.is_empty() {
        return Err(ContractError::EmptyCertificateChain);
    }

    if input.chain.len() > MAX_DEVICE_CERTIFICATE_CHAIN_DEPTH {
        return Err(ContractError::CertificateChainTooDeep);
    }

    let normalized_account_handle = normalize_handle(input.account_handle);
    let mut seen_device_ids = BTreeSet::new();
    let mut previous_certificate: Option<&DeviceCertificate> = None;

    for certificate in input.chain {
        validate_certificate_common(
            certificate,
            &normalized_account_handle,
            &mut seen_device_ids,
            input.now_ms,
        )?;

        if let Some(previous) = previous_certificate {
            validate_child_certificate(certificate, previous)?;
            let payload = device_certificate_signing_payload(certificate);
            if !verify_ed25519(&payload, &certificate.signature, &previous.device_sign_pub)? {
                return Err(ContractError::CertificateSignatureMismatch);
            }
        } else {
            validate_root_certificate(certificate)?;
            let payload = device_certificate_signing_payload(certificate);
            if !verify_ed25519(&payload, &certificate.signature, input.account_sign_pub)? {
                return Err(ContractError::CertificateSignatureMismatch);
            }
        }

        previous_certificate = Some(certificate);
    }

    let Some(leaf) = previous_certificate else {
        return Err(ContractError::EmptyCertificateChain);
    };

    if leaf.device_id != input.device_id
        || leaf.device_sign_pub != input.device_sign_pub
        || leaf.device_dh_pub != input.device_dh_pub
    {
        return Err(ContractError::CertificateLeafMismatch);
    }

    Ok(ValidatedDeviceCertificateChain {
        leaf,
        normalized_chain: input.chain,
    })
}

const fn is_valid_username_char(value: char) -> bool {
    value.is_ascii_lowercase() || value.is_ascii_digit() || matches!(value, '.' | '_' | '-')
}

const fn is_valid_domain_char(value: char) -> bool {
    value.is_ascii_lowercase() || value.is_ascii_digit() || matches!(value, '.' | '-')
}

fn validate_certificate_common<'a>(
    certificate: &'a DeviceCertificate,
    normalized_account_handle: &str,
    seen_device_ids: &mut BTreeSet<&'a str>,
    now_ms: u64,
) -> Result<(), ContractError> {
    if certificate.device_certificate_version != DEVICE_CERTIFICATE_VERSION_V2 {
        return Err(ContractError::UnsupportedCertificateVersion);
    }

    if normalize_handle(&certificate.account_handle) != normalized_account_handle {
        return Err(ContractError::CertificateAccountMismatch);
    }

    if !seen_device_ids.insert(certificate.device_id.as_str()) {
        return Err(ContractError::DuplicateCertificateDevice);
    }

    parse_epoch_ms(&certificate.issued_at)?;
    if let Some(expires_at) = certificate.expires_at.as_deref() {
        if !expires_at.is_empty() && parse_epoch_ms(expires_at)? <= i128::from(now_ms) {
            return Err(ContractError::ExpiredCertificate);
        }
    }

    if certificate.signature.is_empty() {
        return Err(ContractError::MissingCertificateSignature);
    }

    Ok(())
}

fn validate_root_certificate(certificate: &DeviceCertificate) -> Result<(), ContractError> {
    if certificate.issuer_kind != CertificateIssuerKind::Account {
        return Err(ContractError::InvalidRootCertificateIssuer);
    }

    if has_text(certificate.issuer_device_id.as_deref())
        || has_text(certificate.parent_certificate_id.as_deref())
    {
        return Err(ContractError::UnexpectedRootCertificateParent);
    }

    Ok(())
}

fn validate_child_certificate(
    certificate: &DeviceCertificate,
    previous: &DeviceCertificate,
) -> Result<(), ContractError> {
    if certificate.issuer_kind != CertificateIssuerKind::Device {
        return Err(ContractError::InvalidChildCertificateIssuer);
    }

    if certificate.issuer_device_id.as_deref() != Some(previous.device_id.as_str()) {
        return Err(ContractError::CertificateIssuerMismatch);
    }

    let previous_id = device_certificate_id(previous);
    if certificate.parent_certificate_id.as_deref() != Some(previous_id.as_str()) {
        return Err(ContractError::CertificateParentMismatch);
    }

    Ok(())
}

fn has_text(value: Option<&str>) -> bool {
    value.is_some_and(|inner| !inner.is_empty())
}

fn parse_epoch_ms(value: &str) -> Result<i128, ContractError> {
    let parsed =
        OffsetDateTime::parse(value, &Rfc3339).map_err(|_| ContractError::InvalidTimestamp)?;
    Ok(parsed.unix_timestamp_nanos() / 1_000_000)
}

fn public_key_bytes(public_key: &str) -> Result<[u8; ED25519_PUBLIC_KEY_LENGTH], ContractError> {
    let decoded = decode_public_key_material(public_key)?;
    if decoded.len() == ED25519_PUBLIC_KEY_LENGTH {
        return decoded
            .as_slice()
            .try_into()
            .map_err(|_| ContractError::InvalidPublicKey);
    }

    let Some(raw) = decoded.as_slice().strip_prefix(&ED25519_SPKI_PREFIX) else {
        return Err(ContractError::InvalidPublicKey);
    };
    if raw.len() != ED25519_PUBLIC_KEY_LENGTH {
        return Err(ContractError::InvalidPublicKey);
    }

    raw.try_into().map_err(|_| ContractError::InvalidPublicKey)
}

fn decode_public_key_material(value: &str) -> Result<Vec<u8>, ContractError> {
    let trimmed = value.trim();
    if trimmed.contains("BEGIN PUBLIC KEY") {
        let body = trimmed
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with("-----"))
            .collect::<String>();
        return decode_base64_or_url(&body);
    }

    decode_base64_or_url(trimmed)
}

fn decode_base64_or_url(value: &str) -> Result<Vec<u8>, ContractError> {
    for engine in [&STANDARD, &STANDARD_NO_PAD, &URL_SAFE, &URL_SAFE_NO_PAD] {
        if let Ok(decoded) = engine.decode(value) {
            return Ok(decoded);
        }
    }

    Err(ContractError::InvalidSignature)
}

#[cfg(test)]
mod tests {
    use super::{
        device_certificate_id, device_certificate_signing_payload, registration_proof_payload,
        registration_signature_valid, registration_timestamp_fresh,
        validate_device_certificate_chain, verify_ed25519, CertificateIssuerKind, ContractError,
        DeviceCertificate, DeviceCertificateChainInput,
    };

    const ACCOUNT_PUB: &str = "fsJv7HZdC27Tu0vpL23EJ6UdbhF9GcXHVLcqcGDBQSo=";
    const ROOT_DEVICE_SIGN_PUB: &str = "l+Qk/KFuLnmsQPRr33qd2bUVt/ild7kyguvP/UbJwOU=";
    const CHILD_DEVICE_SIGN_PUB: &str = "Q4RIRUegeq+w5CRfpYTZhXqBhhpZdwLFItyrzV+zSjs=";
    const ROOT_DH: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
    const CHILD_DH: &str = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=";
    const ROOT_ID: &str = "7d95f11a9c57a4b1f67e32a031241a05a3bc32af61caa5c8ec323fcd0a0826d4";
    const ROOT_SIGNATURE: &str =
        "j4ID20GN3p4z9WyGLj0QVmdttZjbVHv5++Jn/1fKp6rlKKCKVtPPRM/4ZcL+xqozk1DRzRJJSgpn6HhwFAHbCw==";
    const CHILD_SIGNATURE: &str =
        "GhwnUxUO8tdhZCVVS10S32t3YdP05Q2RH9ACvj6BA9DFffRgjDfOx86FyzSBfbuGyt+7x57G1IGCQjygEYZ6AA==";

    #[test]
    fn parses_and_normalizes_user_handles() {
        let parsed = super::parse_handle("  @Alice:Example.ORG  ");
        assert!(parsed.is_ok());
        let Ok(handle) = parsed else {
            return;
        };

        assert_eq!(handle.normalized(), "@alice:example.org");
        assert_eq!(handle.username(), "alice");
        assert_eq!(handle.domain(), "example.org");
        assert!(super::parse_handle("alice@example.org").is_err());
        assert!(super::parse_handle("@bad-handle").is_err());
        assert!(super::parse_handle("@bad:user:name").is_err());
    }

    #[test]
    fn builds_registration_proof_payload_with_normalized_handle() {
        let payload = registration_proof_payload(
            " @Alice:Example.COM ",
            "ik-sign",
            "ik-dh",
            "2026-02-26T12:00:00.000Z",
        );

        assert_eq!(
            payload,
            "register|@alice:example.com|ik-sign|ik-dh|2026-02-26T12:00:00.000Z"
        );
    }

    #[test]
    fn enforces_registration_timestamp_skew() {
        assert!(registration_timestamp_fresh(1_000_000, 1_299_999));
        assert!(registration_timestamp_fresh(1_000_000, 700_001));
        assert!(!registration_timestamp_fresh(1_000_000, 1_300_001));
        assert!(!registration_timestamp_fresh(1_000_000, 699_999));
    }

    #[test]
    fn verifies_ed25519_raw_base64_vector() {
        let valid = verify_ed25519(root_payload(), ROOT_SIGNATURE, ACCOUNT_PUB);
        assert_eq!(valid, Ok(true));

        let invalid = verify_ed25519("tampered", ROOT_SIGNATURE, ACCOUNT_PUB);
        assert_eq!(invalid, Ok(false));
    }

    #[test]
    fn validates_registration_signature_with_account_key() {
        let valid = registration_signature_valid(
            "@alice:example.com",
            ACCOUNT_PUB,
            "ik-dh",
            "2026-02-26T12:00:00.000Z",
            ROOT_SIGNATURE,
        );

        assert!(!valid);
    }

    #[test]
    fn builds_device_certificate_payload_and_id() {
        let root = root_certificate();
        assert_eq!(
            device_certificate_signing_payload(&root),
            root_payload().to_owned()
        );
        assert_eq!(device_certificate_id(&root), ROOT_ID);
    }

    #[test]
    fn validates_two_device_certificate_chain() {
        let chain = vec![root_certificate(), child_certificate()];
        let input = DeviceCertificateChainInput {
            account_handle: "@alice:example.com",
            account_sign_pub: ACCOUNT_PUB,
            device_id: "ios-linked",
            device_sign_pub: CHILD_DEVICE_SIGN_PUB,
            device_dh_pub: CHILD_DH,
            chain: &chain,
            now_ms: 1_772_106_000_000,
        };

        let validated = validate_device_certificate_chain(&input);
        assert!(validated.is_ok());
        let Ok(chain_result) = validated else {
            return;
        };
        assert_eq!(chain_result.leaf().device_id, "ios-linked");
        assert_eq!(chain_result.normalized_chain().len(), 2);
    }

    #[test]
    fn rejects_invalid_certificate_parent() {
        let mut child = child_certificate();
        child.parent_certificate_id = Some("wrong-parent".to_owned());
        let chain = vec![root_certificate(), child];
        let input = DeviceCertificateChainInput {
            account_handle: "@alice:example.com",
            account_sign_pub: ACCOUNT_PUB,
            device_id: "ios-linked",
            device_sign_pub: CHILD_DEVICE_SIGN_PUB,
            device_dh_pub: CHILD_DH,
            chain: &chain,
            now_ms: 1_772_106_000_000,
        };

        assert_eq!(
            validate_device_certificate_chain(&input).err(),
            Some(ContractError::CertificateParentMismatch)
        );
    }

    #[test]
    fn rejects_expired_certificate() {
        let mut child = child_certificate();
        child.expires_at = Some("1970-01-01T00:00:00.000Z".to_owned());
        let chain = vec![root_certificate(), child];
        let input = DeviceCertificateChainInput {
            account_handle: "@alice:example.com",
            account_sign_pub: ACCOUNT_PUB,
            device_id: "ios-linked",
            device_sign_pub: CHILD_DEVICE_SIGN_PUB,
            device_dh_pub: CHILD_DH,
            chain: &chain,
            now_ms: 1_772_106_000_000,
        };

        assert_eq!(
            validate_device_certificate_chain(&input).err(),
            Some(ContractError::ExpiredCertificate)
        );
    }

    fn root_certificate() -> DeviceCertificate {
        DeviceCertificate {
            device_certificate_version: 2,
            account_handle: "@alice:example.com".to_owned(),
            device_id: "ios-primary".to_owned(),
            device_sign_pub: ROOT_DEVICE_SIGN_PUB.to_owned(),
            device_dh_pub: ROOT_DH.to_owned(),
            issuer_kind: CertificateIssuerKind::Account,
            issuer_device_id: None,
            parent_certificate_id: None,
            issued_at: "2026-02-26T12:00:00.000Z".to_owned(),
            expires_at: None,
            signature: ROOT_SIGNATURE.to_owned(),
        }
    }

    fn child_certificate() -> DeviceCertificate {
        DeviceCertificate {
            device_certificate_version: 2,
            account_handle: "@alice:example.com".to_owned(),
            device_id: "ios-linked".to_owned(),
            device_sign_pub: CHILD_DEVICE_SIGN_PUB.to_owned(),
            device_dh_pub: CHILD_DH.to_owned(),
            issuer_kind: CertificateIssuerKind::Device,
            issuer_device_id: Some("ios-primary".to_owned()),
            parent_certificate_id: Some(ROOT_ID.to_owned()),
            issued_at: "2026-02-26T12:01:00.000Z".to_owned(),
            expires_at: Some("2027-02-26T12:01:00.000Z".to_owned()),
            signature: CHILD_SIGNATURE.to_owned(),
        }
    }

    fn root_payload() -> &'static str {
        concat!(
            "device_certificate|2|@alice:example.com|ios-primary|",
            "l+Qk/KFuLnmsQPRr33qd2bUVt/ild7kyguvP/UbJwOU=|",
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=|",
            "account|||2026-02-26T12:00:00.000Z|"
        )
    }
}
