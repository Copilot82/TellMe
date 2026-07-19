//! Prekey publish and bundle contract for `TellMe` protocol v2.

use crate::auth::{normalize_handle, DeviceCertificate};
use crate::devices::PushMode;
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt::{Display, Formatter};

/// Current protocol version exposed in prekey bundles.
pub const PROTOCOL_VERSION_V2: u8 = 2;

/// Signed prekey payload published by one device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedPrekey {
    pub prekey_id: String,
    pub signed_prekey_pub: String,
    pub signature: String,
    pub expires_at: Option<String>,
}

/// One-time prekey payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OneTimePrekey {
    pub prekey_id: String,
    pub prekey_pub: String,
}

/// Prekey publish request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrekeyPublishRequest {
    pub protocol_version: Option<u8>,
    pub device_id: String,
    pub signed_prekey: SignedPrekey,
    pub one_time_prekeys: Vec<OneTimePrekey>,
}

/// Prekey bundle returned to clients and federation peers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrekeyBundle {
    pub protocol_version: u8,
    pub user_handle: String,
    pub account_sign_pub: String,
    pub device_id: String,
    pub device_sign_pub: String,
    pub device_dh_pub: String,
    pub device_certificate_chain: Vec<DeviceCertificate>,
    pub signed_prekey: SignedPrekey,
    pub one_time_prekey: Option<OneTimePrekey>,
    pub push_mode: PushMode,
}

/// Input used to build one prekey bundle.
#[derive(Debug, Clone, Copy)]
pub struct PrekeyBundleInput<'a> {
    pub user_handle: &'a str,
    pub account_sign_pub: &'a str,
    pub device_id: &'a str,
    pub device_sign_pub: &'a str,
    pub device_dh_pub: &'a str,
    pub device_certificate_chain: &'a [DeviceCertificate],
    pub signed_prekey: Option<&'a SignedPrekey>,
    pub one_time_prekey: Option<&'a OneTimePrekey>,
    pub push_mode: PushMode,
}

/// Prekey contract error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrekeyError {
    UnsupportedProtocolVersion,
    DeviceMismatch,
    DeviceNotActive,
    InvalidSignedPrekey,
    InvalidOneTimePrekey,
}

impl Display for PrekeyError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedProtocolVersion => {
                formatter.write_str("unsupported prekey protocol version")
            }
            Self::DeviceMismatch => {
                formatter.write_str("can only publish prekeys for current device")
            }
            Self::DeviceNotActive => formatter.write_str("device is not active"),
            Self::InvalidSignedPrekey => formatter.write_str("invalid signed prekey"),
            Self::InvalidOneTimePrekey => formatter.write_str("invalid one-time prekey"),
        }
    }
}

impl Error for PrekeyError {}

/// Validates the current `/prekeys/publish` request contract.
///
/// # Errors
///
/// Returns an error when the request targets another device, an inactive device, an unsupported
/// protocol version, or empty required prekey fields.
pub fn validate_publish_request(
    request: &PrekeyPublishRequest,
    current_device_id: &str,
    device_is_active: bool,
) -> Result<(), PrekeyError> {
    if request
        .protocol_version
        .is_some_and(|version| version != PROTOCOL_VERSION_V2)
    {
        return Err(PrekeyError::UnsupportedProtocolVersion);
    }

    if request.device_id != current_device_id {
        return Err(PrekeyError::DeviceMismatch);
    }

    if !device_is_active {
        return Err(PrekeyError::DeviceNotActive);
    }

    if request.signed_prekey.prekey_id.is_empty()
        || request.signed_prekey.signed_prekey_pub.is_empty()
        || request.signed_prekey.signature.is_empty()
    {
        return Err(PrekeyError::InvalidSignedPrekey);
    }

    if request
        .one_time_prekeys
        .iter()
        .any(|prekey| prekey.prekey_id.is_empty() || prekey.prekey_pub.is_empty())
    {
        return Err(PrekeyError::InvalidOneTimePrekey);
    }

    Ok(())
}

#[must_use]
pub fn build_prekey_bundle(input: &PrekeyBundleInput<'_>) -> Option<PrekeyBundle> {
    input.signed_prekey.map(|signed_prekey| PrekeyBundle {
        protocol_version: PROTOCOL_VERSION_V2,
        user_handle: input.user_handle.to_owned(),
        account_sign_pub: input.account_sign_pub.to_owned(),
        device_id: input.device_id.to_owned(),
        device_sign_pub: input.device_sign_pub.to_owned(),
        device_dh_pub: input.device_dh_pub.to_owned(),
        device_certificate_chain: input.device_certificate_chain.to_vec(),
        signed_prekey: signed_prekey.clone(),
        one_time_prekey: input.one_time_prekey.cloned(),
        push_mode: input.push_mode,
    })
}

#[must_use]
pub fn one_time_for_bundle(peek: bool, consumed: Option<OneTimePrekey>) -> Option<OneTimePrekey> {
    if peek {
        None
    } else {
        consumed
    }
}

#[must_use]
pub fn parse_peek_query(value: Option<&str>) -> bool {
    value
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .is_some_and(|normalized| normalized == "true")
}

#[must_use]
pub fn normalize_prekey_user_query(value: Option<&str>) -> Option<String> {
    let normalized = normalize_handle(value.unwrap_or_default());
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

#[must_use]
pub fn bundle_push_mode(modes: &[PushMode]) -> PushMode {
    if modes.contains(&PushMode::FastNotify) {
        PushMode::FastNotify
    } else {
        PushMode::PrivacyFirst
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_prekey_bundle, bundle_push_mode, normalize_prekey_user_query, one_time_for_bundle,
        parse_peek_query, validate_publish_request, OneTimePrekey, PrekeyBundleInput, PrekeyError,
        PrekeyPublishRequest, SignedPrekey,
    };
    use crate::devices::PushMode;

    #[test]
    fn validates_publish_request_for_current_active_device() {
        let request = publish_request(Some(2), "dev-1");

        assert_eq!(validate_publish_request(&request, "dev-1", true), Ok(()));
    }

    #[test]
    fn rejects_publish_for_other_device_or_protocol() {
        let other_device = publish_request(Some(2), "dev-2");
        assert_eq!(
            validate_publish_request(&other_device, "dev-1", true),
            Err(PrekeyError::DeviceMismatch)
        );

        let unsupported = publish_request(Some(1), "dev-1");
        assert_eq!(
            validate_publish_request(&unsupported, "dev-1", true),
            Err(PrekeyError::UnsupportedProtocolVersion)
        );

        let inactive = publish_request(None, "dev-1");
        assert_eq!(
            validate_publish_request(&inactive, "dev-1", false),
            Err(PrekeyError::DeviceNotActive)
        );
    }

    #[test]
    fn rejects_empty_prekey_fields() {
        let mut request = publish_request(None, "dev-1");
        request.signed_prekey.signature = String::new();
        assert_eq!(
            validate_publish_request(&request, "dev-1", true),
            Err(PrekeyError::InvalidSignedPrekey)
        );

        let mut request = publish_request(None, "dev-1");
        request.one_time_prekeys.push(OneTimePrekey {
            prekey_id: String::new(),
            prekey_pub: "otp-pub".to_owned(),
        });
        assert_eq!(
            validate_publish_request(&request, "dev-1", true),
            Err(PrekeyError::InvalidOneTimePrekey)
        );
    }

    #[test]
    fn omits_one_time_prekey_when_peeking() {
        let consumed = Some(OneTimePrekey {
            prekey_id: "otp-1".to_owned(),
            prekey_pub: "otp-pub".to_owned(),
        });

        assert_eq!(one_time_for_bundle(true, consumed.clone()), None);
        assert_eq!(one_time_for_bundle(false, consumed.clone()), consumed);
    }

    #[test]
    fn builds_protocol_v2_bundle_when_signed_prekey_exists() {
        let signed_prekey = signed_prekey();
        let one_time = OneTimePrekey {
            prekey_id: "otp-1".to_owned(),
            prekey_pub: "otp-pub".to_owned(),
        };
        let input = PrekeyBundleInput {
            user_handle: "@alice:example.com",
            account_sign_pub: "ik-sign",
            device_id: "dev-1",
            device_sign_pub: "dk-sign",
            device_dh_pub: "dk-dh",
            device_certificate_chain: &[],
            signed_prekey: Some(&signed_prekey),
            one_time_prekey: Some(&one_time),
            push_mode: PushMode::PrivacyFirst,
        };

        let bundle = build_prekey_bundle(&input);
        assert!(bundle.is_some());
        let Some(bundle) = bundle else {
            return;
        };
        assert_eq!(bundle.protocol_version, 2);
        assert_eq!(bundle.user_handle, "@alice:example.com");
        assert_eq!(bundle.signed_prekey.prekey_id, "signed-1");
        assert_eq!(
            bundle
                .one_time_prekey
                .as_ref()
                .map(|prekey| prekey.prekey_id.as_str()),
            Some("otp-1")
        );
        assert_eq!(bundle.push_mode, PushMode::PrivacyFirst);
    }

    #[test]
    fn skips_bundle_when_signed_prekey_is_absent() {
        let input = PrekeyBundleInput {
            user_handle: "@alice:example.com",
            account_sign_pub: "ik-sign",
            device_id: "dev-1",
            device_sign_pub: "dk-sign",
            device_dh_pub: "dk-dh",
            device_certificate_chain: &[],
            signed_prekey: None,
            one_time_prekey: None,
            push_mode: PushMode::PrivacyFirst,
        };

        assert_eq!(build_prekey_bundle(&input), None);
    }

    #[test]
    fn parses_peek_and_user_query_like_current_route() {
        assert!(parse_peek_query(Some(" TRUE ")));
        assert!(!parse_peek_query(Some("1")));
        assert!(!parse_peek_query(None));
        assert_eq!(
            normalize_prekey_user_query(Some(" @Alice:Example.COM ")).as_deref(),
            Some("@alice:example.com")
        );
        assert_eq!(normalize_prekey_user_query(Some("  ")), None);
    }

    #[test]
    fn uses_fast_notify_when_any_enabled_token_requests_it() {
        assert_eq!(bundle_push_mode(&[]), PushMode::PrivacyFirst);
        assert_eq!(
            bundle_push_mode(&[PushMode::PrivacyFirst, PushMode::FastNotify]),
            PushMode::FastNotify
        );
    }

    fn publish_request(protocol_version: Option<u8>, device_id: &str) -> PrekeyPublishRequest {
        PrekeyPublishRequest {
            protocol_version,
            device_id: device_id.to_owned(),
            signed_prekey: signed_prekey(),
            one_time_prekeys: vec![OneTimePrekey {
                prekey_id: "otp-1".to_owned(),
                prekey_pub: "otp-pub".to_owned(),
            }],
        }
    }

    fn signed_prekey() -> SignedPrekey {
        SignedPrekey {
            prekey_id: "signed-1".to_owned(),
            signed_prekey_pub: "signed-prekey".to_owned(),
            signature: "signed-prekey-signature".to_owned(),
            expires_at: None,
        }
    }
}
