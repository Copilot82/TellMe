//! Device registration and linking protocol contract.

use crate::auth::{
    device_certificate_id, validate_device_certificate_chain, verify_ed25519,
    CertificateIssuerKind, ContractError, DeviceCertificate, DeviceCertificateChainInput,
    ValidatedDeviceCertificateChain,
};
use crate::hashing::sha256_hex;
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt::{Display, Formatter};

/// Minimum device-link session lifetime accepted by the current API.
pub const LINK_EXPIRES_MIN_SEC: u64 = 30;

/// Maximum device-link session lifetime accepted by the current API.
pub const LINK_EXPIRES_MAX_SEC: u64 = 900;

/// Default device-link session lifetime used by the current API.
pub const LINK_EXPIRES_DEFAULT_SEC: u64 = 300;

/// Public keys advertised by one device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DevicePublicKeys {
    device_id: String,
    dk_sign_pub: String,
    dk_dh_pub: String,
}

impl DevicePublicKeys {
    #[must_use]
    pub const fn new(device_id: String, dk_sign_pub: String, dk_dh_pub: String) -> Self {
        Self {
            device_id,
            dk_sign_pub,
            dk_dh_pub,
        }
    }

    #[must_use]
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    #[must_use]
    pub fn dk_sign_pub(&self) -> &str {
        &self.dk_sign_pub
    }

    #[must_use]
    pub fn dk_dh_pub(&self) -> &str {
        &self.dk_dh_pub
    }
}

/// Push notification privacy mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushMode {
    PrivacyFirst,
    FastNotify,
}

impl PushMode {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::PrivacyFirst => "privacy_first",
            Self::FastNotify => "fast_notify",
        }
    }
}

/// APNs token surface. Alert tokens receive ordinary sync wakes; `VoIP` tokens only receive opaque call wakes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushTokenKind {
    Alert,
    Voip,
}

impl PushTokenKind {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Alert => "alert",
            Self::Voip => "voip",
        }
    }
}

/// Device domain error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceError {
    AuthContract(ContractError),
    LinkExpiryOutOfRange,
    EmptyHostCertificateChain,
    InvalidApprovedDeviceCertificate,
}

impl Display for DeviceError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AuthContract(error) => write!(formatter, "{error}"),
            Self::LinkExpiryOutOfRange => formatter.write_str("device link expiry is out of range"),
            Self::EmptyHostCertificateChain => {
                formatter.write_str("host device certificate chain is empty")
            }
            Self::InvalidApprovedDeviceCertificate => {
                formatter.write_str("invalid approved device certificate")
            }
        }
    }
}

impl Error for DeviceError {}

impl From<ContractError> for DeviceError {
    fn from(value: ContractError) -> Self {
        Self::AuthContract(value)
    }
}

/// Input for `/devices/register` certificate validation.
#[derive(Debug, Clone, Copy)]
pub struct DeviceRegistrationInput<'a> {
    pub account_handle: &'a str,
    pub account_sign_pub: &'a str,
    pub device_keys: &'a DevicePublicKeys,
    pub certificate_chain: &'a [DeviceCertificate],
    pub now_ms: u64,
}

/// Input for approving one device-link request.
#[derive(Debug, Clone, Copy)]
pub struct DeviceLinkApprovalInput<'a> {
    pub account_handle: &'a str,
    pub account_sign_pub: &'a str,
    pub host_device_id: &'a str,
    pub host_certificate_chain: &'a [DeviceCertificate],
    pub approved_certificate: &'a DeviceCertificate,
    pub new_device_keys: &'a DevicePublicKeys,
    pub now_ms: u64,
}

/// Validates a newly registered device certificate chain against its public keys.
///
/// # Errors
///
/// Returns an error when the certificate chain does not authenticate the provided device keys.
pub fn validate_device_registration<'a>(
    input: &DeviceRegistrationInput<'a>,
) -> Result<ValidatedDeviceCertificateChain<'a>, DeviceError> {
    let chain_input = DeviceCertificateChainInput {
        account_handle: input.account_handle,
        account_sign_pub: input.account_sign_pub,
        device_id: input.device_keys.device_id(),
        device_sign_pub: input.device_keys.dk_sign_pub(),
        device_dh_pub: input.device_keys.dk_dh_pub(),
        chain: input.certificate_chain,
        now_ms: input.now_ms,
    };

    validate_device_certificate_chain(&chain_input).map_err(DeviceError::from)
}

/// Validates a device-link approval certificate and returns the full approved chain.
///
/// # Errors
///
/// Returns an error when the host chain is missing, the approved certificate does not extend the host
/// device, or the resulting full chain is invalid.
pub fn validate_device_link_approval(
    input: &DeviceLinkApprovalInput<'_>,
) -> Result<Vec<DeviceCertificate>, DeviceError> {
    let host_leaf = input
        .host_certificate_chain
        .last()
        .ok_or(DeviceError::EmptyHostCertificateChain)?;
    let host_leaf_id = device_certificate_id(host_leaf);

    if input.approved_certificate.issuer_kind != CertificateIssuerKind::Device
        || input.approved_certificate.issuer_device_id.as_deref() != Some(input.host_device_id)
        || input.approved_certificate.parent_certificate_id.as_deref()
            != Some(host_leaf_id.as_str())
    {
        return Err(DeviceError::InvalidApprovedDeviceCertificate);
    }

    let mut full_chain = input.host_certificate_chain.to_vec();
    full_chain.push(input.approved_certificate.clone());

    let chain_input = DeviceCertificateChainInput {
        account_handle: input.account_handle,
        account_sign_pub: input.account_sign_pub,
        device_id: input.new_device_keys.device_id(),
        device_sign_pub: input.new_device_keys.dk_sign_pub(),
        device_dh_pub: input.new_device_keys.dk_dh_pub(),
        chain: &full_chain,
        now_ms: input.now_ms,
    };
    validate_device_certificate_chain(&chain_input)?;

    Ok(full_chain)
}

#[must_use]
pub fn revoke_proof(device_id: &str, timestamp_iso: Option<&str>) -> String {
    format!("revoke|{device_id}|{}", timestamp_iso.unwrap_or_default())
}

#[must_use]
pub fn revoke_signature_valid(
    device_id: &str,
    timestamp_iso: Option<&str>,
    signature_base64: &str,
    current_device_sign_pub: &str,
) -> bool {
    let proof = revoke_proof(device_id, timestamp_iso);
    verify_ed25519(&proof, signature_base64, current_device_sign_pub).unwrap_or(false)
}

/// Applies the current device-link expiry bounds.
///
/// # Errors
///
/// Returns an error when the provided lifetime is outside `30..=900` seconds.
pub const fn effective_link_expires_sec(value: Option<u64>) -> Result<u64, DeviceError> {
    match value {
        Some(inner) if inner < LINK_EXPIRES_MIN_SEC || inner > LINK_EXPIRES_MAX_SEC => {
            Err(DeviceError::LinkExpiryOutOfRange)
        }
        Some(inner) => Ok(inner),
        None => Ok(LINK_EXPIRES_DEFAULT_SEC),
    }
}

#[must_use]
pub fn link_secret_hash(secret: &str) -> String {
    sha256_hex(secret.as_bytes())
}

#[must_use]
pub fn effective_push_mode(value: Option<&str>) -> PushMode {
    match value {
        Some("fast_notify") => PushMode::FastNotify,
        _ => PushMode::PrivacyFirst,
    }
}

#[must_use]
pub fn effective_push_token_kind(value: Option<&str>) -> PushTokenKind {
    match value {
        Some("voip") => PushTokenKind::Voip,
        _ => PushTokenKind::Alert,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        effective_link_expires_sec, effective_push_mode, effective_push_token_kind,
        link_secret_hash, revoke_proof, revoke_signature_valid, validate_device_link_approval,
        validate_device_registration, DeviceError, DeviceLinkApprovalInput, DevicePublicKeys,
        DeviceRegistrationInput, PushMode, PushTokenKind,
    };
    use crate::auth::{CertificateIssuerKind, DeviceCertificate};

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
    const REVOKE_DEVICE_PUB: &str = "YuG0HWpdNm7k47p4eJwLhQF+VekLkI86pXQcPgETaPw=";
    const REVOKE_SIGNATURE: &str =
        "0Ovz24epKxR75G405kr6xLLywcbvBAPA7qmCjl+qUZMbzajFt2KhCgMbb9DkgFXwKh4TZSDnwtXMAqqVyZrwBg==";

    #[test]
    fn validates_registered_device_chain() {
        let chain = vec![root_certificate()];
        let keys = root_device_keys();
        let input = DeviceRegistrationInput {
            account_handle: "@alice:example.com",
            account_sign_pub: ACCOUNT_PUB,
            device_keys: &keys,
            certificate_chain: &chain,
            now_ms: 1_772_106_000_000,
        };

        let validated = validate_device_registration(&input);
        assert!(validated.is_ok());
    }

    #[test]
    fn validates_link_approval_extending_host_chain() {
        let host_chain = vec![root_certificate()];
        let child = child_certificate();
        let keys = child_device_keys();
        let input = DeviceLinkApprovalInput {
            account_handle: "@alice:example.com",
            account_sign_pub: ACCOUNT_PUB,
            host_device_id: "ios-primary",
            host_certificate_chain: &host_chain,
            approved_certificate: &child,
            new_device_keys: &keys,
            now_ms: 1_772_106_000_000,
        };

        let approved = validate_device_link_approval(&input);
        assert!(approved.is_ok());
        let Ok(full_chain) = approved else {
            return;
        };
        assert_eq!(full_chain.len(), 2);
        assert_eq!(
            full_chain.last().map(|cert| cert.device_id.as_str()),
            Some("ios-linked")
        );
    }

    #[test]
    fn rejects_link_approval_with_wrong_parent() {
        let host_chain = vec![root_certificate()];
        let mut child = child_certificate();
        child.parent_certificate_id = Some("wrong-parent".to_owned());
        let keys = child_device_keys();
        let input = DeviceLinkApprovalInput {
            account_handle: "@alice:example.com",
            account_sign_pub: ACCOUNT_PUB,
            host_device_id: "ios-primary",
            host_certificate_chain: &host_chain,
            approved_certificate: &child,
            new_device_keys: &keys,
            now_ms: 1_772_106_000_000,
        };

        assert_eq!(
            validate_device_link_approval(&input).err(),
            Some(DeviceError::InvalidApprovedDeviceCertificate)
        );
    }

    #[test]
    fn builds_and_verifies_revoke_proof() {
        assert_eq!(
            revoke_proof("ios-old", Some("2026-02-26T12:00:00.000Z")),
            "revoke|ios-old|2026-02-26T12:00:00.000Z"
        );
        assert_eq!(revoke_proof("ios-old", None), "revoke|ios-old|");
        assert!(revoke_signature_valid(
            "ios-old",
            Some("2026-02-26T12:00:00.000Z"),
            REVOKE_SIGNATURE,
            REVOKE_DEVICE_PUB
        ));
        assert!(!revoke_signature_valid(
            "ios-other",
            Some("2026-02-26T12:00:00.000Z"),
            REVOKE_SIGNATURE,
            REVOKE_DEVICE_PUB
        ));
    }

    #[test]
    fn hashes_link_secrets_and_maps_modes() {
        assert_eq!(
            link_secret_hash("link-code"),
            "146abdd53dad74c33e75b1898391ee5db352d2fce2bcdfa78850db66b073d73c"
        );
        assert_eq!(
            effective_push_mode(Some("fast_notify")),
            PushMode::FastNotify
        );
        assert_eq!(
            effective_push_mode(Some("anything")),
            PushMode::PrivacyFirst
        );
        assert_eq!(effective_push_mode(None), PushMode::PrivacyFirst);
        assert_eq!(effective_push_token_kind(Some("voip")), PushTokenKind::Voip);
        assert_eq!(
            effective_push_token_kind(Some("anything")),
            PushTokenKind::Alert
        );
        assert_eq!(effective_push_token_kind(None), PushTokenKind::Alert);
    }

    #[test]
    fn constrains_link_expiry_like_joi_schema() {
        assert_eq!(effective_link_expires_sec(None), Ok(300));
        assert_eq!(effective_link_expires_sec(Some(30)), Ok(30));
        assert_eq!(effective_link_expires_sec(Some(900)), Ok(900));
        assert_eq!(
            effective_link_expires_sec(Some(29)),
            Err(DeviceError::LinkExpiryOutOfRange)
        );
        assert_eq!(
            effective_link_expires_sec(Some(901)),
            Err(DeviceError::LinkExpiryOutOfRange)
        );
    }

    fn root_device_keys() -> DevicePublicKeys {
        DevicePublicKeys::new(
            "ios-primary".to_owned(),
            ROOT_DEVICE_SIGN_PUB.to_owned(),
            ROOT_DH.to_owned(),
        )
    }

    fn child_device_keys() -> DevicePublicKeys {
        DevicePublicKeys::new(
            "ios-linked".to_owned(),
            CHILD_DEVICE_SIGN_PUB.to_owned(),
            CHILD_DH.to_owned(),
        )
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
}
