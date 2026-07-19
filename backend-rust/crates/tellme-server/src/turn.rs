//! Privacy-first TURN credential contract for WebRTC relay-only calls.
//!
//! The endpoint is intentionally stateless. It issues relay credentials derived from a server-side
//! `TURN_STATIC_SECRET` and rejects any request fields that could identify a call, conversation, peer, or device.

use crate::auth_service::ApiError;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine as _;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use std::env;

type HmacSha1 = Hmac<Sha1>;

/// Minimum accepted lifetime for credentials that may open a new TURN allocation.
pub const TURN_CREDENTIAL_TTL_MIN_SEC: u64 = 60;

/// Maximum accepted lifetime for credentials that may open a new TURN allocation.
pub const TURN_CREDENTIAL_TTL_MAX_SEC: u64 = 900;

/// Default lifetime for credentials that may open a new TURN allocation.
///
/// Established allocations have their own lifetime and are maintained by TURN refresh requests.
pub const TURN_CREDENTIAL_TTL_DEFAULT_SEC: u64 = 300;

/// Request body for `/api/turn/credentials`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
// TURN credentials are scoped to calls and expose relay access without exposing media content.
pub struct TurnCredentialsRequest {
    pub purpose: String,
    pub transport_profile: String,
    pub capabilities: Option<serde_json::Value>,
}

/// One WebRTC ICE server entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TurnIceServer {
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
}

/// Ephemeral TURN credential payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TurnCredentialPayload {
    pub username: String,
    pub credential: String,
    pub expires_at: u64,
    pub ttl: u64,
}

/// Response body for `/api/turn/credentials`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TurnCredentialsResponse {
    pub ice_servers: Vec<TurnIceServer>,
    pub turn_credentials: TurnCredentialPayload,
    pub ice_transport_policy: &'static str,
    pub transport_profile: &'static str,
}

/// Sanitized TURN runtime config.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnConfig {
    urls: Vec<String>,
    static_secret: String,
    ttl_sec: u64,
}

impl TurnConfig {
    /// Loads TURN credential config from environment variables.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when required TURN config is missing or unsafe for relay-only release-1.
    pub fn from_env() -> Result<Self, ApiError> {
        let urls = turn_urls_from_env()?;
        let static_secret = env::var("TURN_STATIC_SECRET")
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
            .ok_or_else(ApiError::internal)?;
        let ttl_sec = env::var("TURN_CREDENTIAL_TTL_SEC")
            .ok()
            .and_then(|value| value.trim().parse::<u64>().ok())
            .unwrap_or(TURN_CREDENTIAL_TTL_DEFAULT_SEC)
            .clamp(TURN_CREDENTIAL_TTL_MIN_SEC, TURN_CREDENTIAL_TTL_MAX_SEC);

        Self::new(urls, static_secret, ttl_sec)
    }

    /// Builds explicit TURN config.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when URL or TTL values violate the relay-only profile.
    pub fn new(urls: Vec<String>, static_secret: String, ttl_sec: u64) -> Result<Self, ApiError> {
        let filtered = urls
            .into_iter()
            .map(|url| url.trim().to_owned())
            .filter(|url| !url.is_empty())
            .collect::<Vec<_>>();
        if filtered.is_empty()
            || filtered
                .iter()
                .any(|url| !(url.starts_with("turn:") || url.starts_with("turns:")))
            || static_secret.trim().is_empty()
            || !(TURN_CREDENTIAL_TTL_MIN_SEC..=TURN_CREDENTIAL_TTL_MAX_SEC).contains(&ttl_sec)
        {
            return Err(ApiError::internal());
        }

        Ok(Self {
            urls: filtered,
            static_secret,
            ttl_sec,
        })
    }
}

/// Creates one ephemeral relay-only TURN credential response using env config.
///
/// # Errors
///
/// Returns `ApiError` when the request is invalid, TURN config is missing, or randomness fails.
pub fn credentials_from_env(
    request: &TurnCredentialsRequest,
    now_epoch_sec: u64,
) -> Result<TurnCredentialsResponse, ApiError> {
    let config = TurnConfig::from_env()?;
    let mut nonce = [0_u8; 16];
    getrandom::getrandom(&mut nonce).map_err(|_| ApiError::internal())?;
    credentials_for_config(request, &config, now_epoch_sec, &nonce)
}

/// Creates one ephemeral relay-only TURN credential response using explicit config.
///
/// # Errors
///
/// Returns `ApiError` when the request is invalid or config cannot sign credentials.
pub fn credentials_for_config(
    request: &TurnCredentialsRequest,
    config: &TurnConfig,
    now_epoch_sec: u64,
    nonce: &[u8],
) -> Result<TurnCredentialsResponse, ApiError> {
    validate_request(request)?;
    let expires_at = now_epoch_sec.saturating_add(config.ttl_sec);
    let nonce = URL_SAFE_NO_PAD.encode(nonce);
    let username = format!("{expires_at}:{nonce}");
    let credential = turn_hmac_credential(&config.static_secret, &username)?;
    let ice_server = TurnIceServer {
        urls: config.urls.clone(),
        username: username.clone(),
        credential: credential.clone(),
    };

    Ok(TurnCredentialsResponse {
        ice_servers: vec![ice_server],
        turn_credentials: TurnCredentialPayload {
            username,
            credential,
            expires_at,
            ttl: config.ttl_sec,
        },
        ice_transport_policy: "relay",
        transport_profile: "webrtc_turn_relay",
    })
}

fn validate_request(request: &TurnCredentialsRequest) -> Result<(), ApiError> {
    if request.purpose != "call_media" || request.transport_profile != "webrtc_turn_relay" {
        return Err(ApiError::bad_request("Invalid TURN credential request"));
    }
    if request
        .capabilities
        .as_ref()
        .is_some_and(capabilities_contain_forbidden_identifiers)
    {
        return Err(ApiError::bad_request("Invalid TURN credential request"));
    }

    Ok(())
}

fn turn_hmac_credential(secret: &str, username: &str) -> Result<String, ApiError> {
    let mut mac = HmacSha1::new_from_slice(secret.as_bytes()).map_err(|_| ApiError::internal())?;
    mac.update(username.as_bytes());
    Ok(STANDARD.encode(mac.finalize().into_bytes()))
}

fn turn_urls_from_env() -> Result<Vec<String>, ApiError> {
    let mut urls = Vec::new();
    for name in [
        "TURN_SERVER_URL_UDP",
        "TURN_SERVER_URL_TCP",
        "TURN_SERVER_URL_TLS",
        "TURN_SERVER_FALLBACK_URL_UDP",
        "TURN_SERVER_FALLBACK_URL_TCP",
    ] {
        if let Ok(value) = env::var(name) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                urls.push(trimmed.to_owned());
            }
        }
    }
    if urls.is_empty() {
        return Err(ApiError::internal());
    }
    Ok(urls)
}

fn capabilities_contain_forbidden_identifiers(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Object(map) => map.keys().any(|key| {
            matches!(
                key.as_str(),
                "call_id"
                    | "conversation_id"
                    | "peer_handle"
                    | "peer_device_id"
                    | "participant_list"
                    | "participants"
            )
        }),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        credentials_for_config, TurnConfig, TurnCredentialsRequest,
        TURN_CREDENTIAL_TTL_DEFAULT_SEC, TURN_CREDENTIAL_TTL_MAX_SEC, TURN_CREDENTIAL_TTL_MIN_SEC,
    };
    use serde_json::json;

    #[test]
    fn issues_ephemeral_relay_only_turn_credentials_without_identifiers() {
        let config = TurnConfig::new(
            vec![
                "turn:turn.example.com:3478?transport=udp".to_owned(),
                "turns:turn.example.com:5349?transport=tcp".to_owned(),
                "turn:203.0.113.10:3478?transport=udp".to_owned(),
                "turn:203.0.113.10:3478?transport=tcp".to_owned(),
            ],
            "static-secret".to_owned(),
            TURN_CREDENTIAL_TTL_DEFAULT_SEC,
        );
        assert!(config.is_ok());
        let Ok(config) = config else {
            return;
        };
        let request = TurnCredentialsRequest {
            purpose: "call_media".to_owned(),
            transport_profile: "webrtc_turn_relay".to_owned(),
            capabilities: Some(json!({"video": true, "audio": true})),
        };

        let response = credentials_for_config(&request, &config, 1_700_000_000, &[7; 16]);

        assert!(response.is_ok());
        let Ok(response) = response else {
            return;
        };
        assert_eq!(response.ice_transport_policy, "relay");
        assert_eq!(response.transport_profile, "webrtc_turn_relay");
        assert_eq!(
            response.turn_credentials.expires_at,
            1_700_000_000 + TURN_CREDENTIAL_TTL_DEFAULT_SEC
        );
        assert!(response.turn_credentials.username.starts_with(&format!(
            "{}:",
            1_700_000_000 + TURN_CREDENTIAL_TTL_DEFAULT_SEC
        )));
        assert!(!response.turn_credentials.username.contains("call"));
        assert!(!response.turn_credentials.username.contains("alice"));
        assert_eq!(response.ice_servers.len(), 1);
        assert!(response.ice_servers.first().is_some_and(|server| server
            .urls
            .contains(&"turn:203.0.113.10:3478?transport=udp".to_owned())));
        assert!(response.ice_servers.first().is_some_and(|server| server
            .urls
            .iter()
            .all(|url| url.starts_with("turn:") || url.starts_with("turns:"))));
    }

    #[test]
    fn rejects_non_turn_urls_and_plaintext_identifiers() {
        assert!(TurnConfig::new(
            vec!["stun:stun.example.com:19302".to_owned()],
            "static-secret".to_owned(),
            TURN_CREDENTIAL_TTL_DEFAULT_SEC,
        )
        .is_err());

        let Ok(config) = TurnConfig::new(
            vec!["turn:turn.example.com:3478".to_owned()],
            "static-secret".to_owned(),
            TURN_CREDENTIAL_TTL_DEFAULT_SEC,
        ) else {
            return;
        };
        let request = TurnCredentialsRequest {
            purpose: "call_media".to_owned(),
            transport_profile: "webrtc_turn_relay".to_owned(),
            capabilities: Some(json!({"call_id": "forbidden"})),
        };

        assert!(credentials_for_config(&request, &config, 1_700_000_000, &[7; 16]).is_err());
    }

    #[test]
    fn accepts_only_bounded_ttl_for_new_turn_allocations() {
        let config_for_ttl = |ttl_sec| {
            TurnConfig::new(
                vec!["turn:turn.example.com:3478".to_owned()],
                "static-secret".to_owned(),
                ttl_sec,
            )
        };

        assert!(config_for_ttl(TURN_CREDENTIAL_TTL_MIN_SEC).is_ok());
        assert!(config_for_ttl(TURN_CREDENTIAL_TTL_DEFAULT_SEC).is_ok());
        assert!(config_for_ttl(TURN_CREDENTIAL_TTL_MAX_SEC).is_ok());
        assert!(config_for_ttl(TURN_CREDENTIAL_TTL_MIN_SEC - 1).is_err());
        assert!(config_for_ttl(TURN_CREDENTIAL_TTL_MAX_SEC + 1).is_err());
    }
}
