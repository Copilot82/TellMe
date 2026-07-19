//! APNs provider boundary for privacy-safe iOS wake notifications.
//!
//! This module owns only provider authentication, APNs HTTP request construction, and response mapping. It keeps the
//! worker-level privacy rule defensive by suppressing call-oriented push hints even if a caller bypasses the normal
//! push-job sanitization path.

use crate::devices::PushMode;
use crate::messages::{push_kind_for_job, PushKind, WakeupClass};
use crate::worker_service::{
    AsyncPushProvider, ProviderPushRequest, ProviderPushResult, PushProviderFuture, WorkerError,
};
use crate::workers::{push_collapse_id, PushEnvironment};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine as _;
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use p256::pkcs8::DecodePrivateKey;
use reqwest::{Client, StatusCode, Version};
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const APNS_PRODUCTION_HOST: &str = "api.push.apple.com";
const APNS_SANDBOX_HOST: &str = "api.sandbox.push.apple.com";
const DEFAULT_APNS_TIMEOUT_MS: u64 = 10_000;
const DEFAULT_APNS_EXPIRY_SEC: u64 = 3_600;
const APNS_PRIORITY: &str = "5";
const APNS_VOIP_PRIORITY: &str = "10";
const APNS_AUTH_ALG: &str = "ES256";

/// APNs runtime configuration loaded from the existing `TellMe` env contract.
#[derive(Clone, PartialEq, Eq)]
// Push providers receive wakeup hints only; message content is never part of this contract.
pub struct ApnsProviderConfig {
    bundle_id: String,
    key_id: String,
    team_id: String,
    private_key_pem: String,
    voip_topic: String,
    timeout_ms: u64,
}

impl ApnsProviderConfig {
    /// Creates explicit APNs provider config.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when required values are empty, timeout is zero, or key material is invalid.
    pub fn new(
        bundle_id: impl Into<String>,
        key_id: impl Into<String>,
        team_id: impl Into<String>,
        private_key_pem: impl Into<String>,
        timeout_ms: u64,
    ) -> Result<Self, WorkerError> {
        let bundle_id = bundle_id.into();
        let key_id = key_id.into();
        let team_id = team_id.into();
        let private_key_pem = private_key_pem.into();
        let trimmed_bundle_id = non_empty(&bundle_id)?;
        let config = Self {
            voip_topic: default_voip_topic(&trimmed_bundle_id),
            bundle_id: trimmed_bundle_id,
            key_id: non_empty(&key_id)?,
            team_id: non_empty(&team_id)?,
            private_key_pem: non_empty(&private_key_pem)?,
            timeout_ms,
        };
        if config.timeout_ms == 0 {
            return Err(WorkerError);
        }
        let _signing_key = signing_key(&config.private_key_pem)?;
        Ok(config)
    }

    /// Builds APNs provider config from `APNS_*` environment variables.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when required values are missing, malformed, or key material cannot be read.
    pub fn from_env() -> Result<Self, WorkerError> {
        let timeout_ms = env::var("APNS_REQUEST_TIMEOUT_MS")
            .ok()
            .map(|value| value.parse::<u64>())
            .transpose()
            .map_err(|_| WorkerError)?
            .unwrap_or(DEFAULT_APNS_TIMEOUT_MS);

        let mut config = Self::new(
            required_env("APNS_BUNDLE_ID")?,
            required_env("APNS_KEY_ID")?,
            required_env("APNS_TEAM_ID")?,
            private_key_from_env()?,
            timeout_ms,
        )?;
        if let Some(topic) = optional_env("APNS_VOIP_TOPIC") {
            config.voip_topic = topic;
        }
        Ok(config)
    }

    #[must_use]
    pub fn bundle_id(&self) -> &str {
        &self.bundle_id
    }

    #[must_use]
    pub fn voip_topic(&self) -> &str {
        &self.voip_topic
    }

    #[must_use]
    pub fn key_id(&self) -> &str {
        &self.key_id
    }

    #[must_use]
    pub fn team_id(&self) -> &str {
        &self.team_id
    }

    #[must_use]
    pub const fn timeout(&self) -> Duration {
        Duration::from_millis(self.timeout_ms)
    }
}

/// Async APNs provider implementation for the Rust push worker runtime.
#[derive(Clone)]
pub struct ApnsPushProvider {
    config: ApnsProviderConfig,
    client: Client,
}

impl ApnsPushProvider {
    /// Creates an APNs provider from explicit config.
    #[must_use]
    pub fn new(config: ApnsProviderConfig) -> Self {
        Self {
            config,
            client: Client::new(),
        }
    }

    /// Creates an APNs provider from environment variables.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when `APNS_*` config is incomplete or invalid.
    pub fn from_env() -> Result<Self, WorkerError> {
        ApnsProviderConfig::from_env().map(Self::new)
    }

    /// Sends one privacy-safe APNs wake notification.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when request signing or JSON serialization fails.
    pub async fn send_request(
        &self,
        request: ProviderPushRequest,
    ) -> Result<ProviderPushResult, WorkerError> {
        let apns_request = self.apns_request(&request)?;
        let response = self
            .client
            .post(&apns_request.url)
            .version(Version::HTTP_2)
            .timeout(self.config.timeout())
            .header("authorization", apns_request.authorization)
            .header("apns-topic", apns_request.apns_topic)
            .header("apns-push-type", apns_request.apns_push_type)
            .header("apns-priority", apns_request.apns_priority)
            .header("apns-expiration", apns_request.apns_expiration)
            .header("apns-collapse-id", apns_request.apns_collapse_id)
            .header("content-type", "application/json")
            .body(apns_request.body)
            .send()
            .await;

        let Ok(response) = response else {
            return Ok(transient_failure("APNs transport error"));
        };
        Ok(map_apns_response(response.status(), response.text().await))
    }

    fn apns_request(&self, request: &ProviderPushRequest) -> Result<ApnsHttpRequest, WorkerError> {
        self.apns_request_at(request, current_epoch_sec()?)
    }

    fn apns_request_at(
        &self,
        request: &ProviderPushRequest,
        issued_at_sec: u64,
    ) -> Result<ApnsHttpRequest, WorkerError> {
        if request.wakeup_class == WakeupClass::VoipOpaque {
            return self.voip_apns_request_at(request, issued_at_sec);
        }

        let safe_push_kind = push_kind_for_job(
            matches!(request.push_mode, PushMode::FastNotify),
            request.push_kind,
        );
        let alert = safe_push_kind.and_then(generic_alert_for_push_kind);
        let is_alert = matches!(request.push_mode, PushMode::FastNotify) && alert.is_some();
        let collapse_id = push_collapse_id(&request.device_id);
        let body = serde_json::to_string(&ApnsPayload {
            aps: ApnsApsPayload {
                content_available: 1,
                mutable_content: if is_alert { Some(1) } else { None },
                alert,
                sound: if is_alert { Some("default") } else { None },
            },
            message_id: &request.message_id,
            device_id: &request.device_id,
            collapse_id: Some(&collapse_id),
            push_mode: request.push_mode.as_wire(),
            push_kind: safe_push_kind.map(PushKind::as_wire),
        })
        .map_err(|_| WorkerError)?;

        Ok(ApnsHttpRequest {
            url: apns_url(request.push_environment, &request.token),
            authorization: format!("bearer {}", self.provider_token(issued_at_sec)?),
            apns_topic: self.config.bundle_id().to_owned(),
            apns_push_type: if is_alert { "alert" } else { "background" }.to_owned(),
            apns_priority: APNS_PRIORITY.to_owned(),
            apns_expiration: (issued_at_sec + DEFAULT_APNS_EXPIRY_SEC).to_string(),
            apns_collapse_id: collapse_id,
            body,
        })
    }

    fn voip_apns_request_at(
        &self,
        request: &ProviderPushRequest,
        issued_at_sec: u64,
    ) -> Result<ApnsHttpRequest, WorkerError> {
        let collapse_id = voip_collapse_id(&request.message_id);
        let body = serde_json::to_string(&ApnsVoipPayload {
            aps: ApnsApsPayload {
                content_available: 1,
                mutable_content: None,
                alert: None,
                sound: None,
            },
            wakeup_class: "voip_opaque",
            sync_id: &request.message_id,
        })
        .map_err(|_| WorkerError)?;

        Ok(ApnsHttpRequest {
            url: apns_url(request.push_environment, &request.token),
            authorization: format!("bearer {}", self.provider_token(issued_at_sec)?),
            apns_topic: self.config.voip_topic().to_owned(),
            apns_push_type: "voip".to_owned(),
            apns_priority: APNS_VOIP_PRIORITY.to_owned(),
            apns_expiration: (issued_at_sec + DEFAULT_APNS_EXPIRY_SEC).to_string(),
            apns_collapse_id: collapse_id,
            body,
        })
    }

    fn provider_token(&self, issued_at_sec: u64) -> Result<String, WorkerError> {
        provider_token_at(
            self.config.team_id(),
            self.config.key_id(),
            &self.config.private_key_pem,
            issued_at_sec,
        )
    }
}

impl AsyncPushProvider for ApnsPushProvider {
    fn send_async(&mut self, request: ProviderPushRequest) -> PushProviderFuture<'_> {
        Box::pin(async move { self.send_request(request).await })
    }
}

struct ApnsHttpRequest {
    url: String,
    authorization: String,
    apns_topic: String,
    apns_push_type: String,
    apns_priority: String,
    apns_expiration: String,
    apns_collapse_id: String,
    body: String,
}

#[derive(Serialize)]
struct ApnsPayload<'a> {
    aps: ApnsApsPayload<'a>,
    message_id: &'a str,
    device_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    collapse_id: Option<&'a str>,
    push_mode: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    push_kind: Option<&'a str>,
}

#[derive(Serialize)]
struct ApnsVoipPayload<'a> {
    aps: ApnsApsPayload<'a>,
    wakeup_class: &'a str,
    sync_id: &'a str,
}

#[derive(Serialize)]
struct ApnsApsPayload<'a> {
    #[serde(rename = "content-available")]
    content_available: u8,
    #[serde(rename = "mutable-content", skip_serializing_if = "Option::is_none")]
    mutable_content: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    alert: Option<GenericAlert<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sound: Option<&'a str>,
}

#[derive(Clone, Copy, Serialize)]
struct GenericAlert<'a> {
    title: &'a str,
    body: &'a str,
}

#[derive(Serialize)]
struct ApnsJwtHeader<'a> {
    alg: &'static str,
    kid: &'a str,
}

#[derive(Serialize)]
struct ApnsJwtClaims<'a> {
    iss: &'a str,
    iat: u64,
}

#[derive(Deserialize)]
struct ApnsFailureBody {
    reason: Option<String>,
}

fn map_apns_response(
    status: StatusCode,
    body_result: Result<String, reqwest::Error>,
) -> ProviderPushResult {
    if status.is_success() {
        return ProviderPushResult {
            ok: true,
            hard_failure_reason: None,
            transient_failure_reason: None,
        };
    }

    let Ok(body) = body_result else {
        return transient_failure("APNs response read error");
    };
    if let Some(reason) = apns_failure_reason(&body) {
        return ProviderPushResult {
            ok: false,
            hard_failure_reason: Some(reason),
            transient_failure_reason: None,
        };
    }

    transient_failure(&format!("APNs HTTP {}", status.as_u16()))
}

fn apns_failure_reason(body: &str) -> Option<String> {
    serde_json::from_str::<ApnsFailureBody>(body)
        .ok()
        .and_then(|payload| payload.reason)
        .filter(|reason| !reason.trim().is_empty())
}

fn transient_failure(reason: &str) -> ProviderPushResult {
    ProviderPushResult {
        ok: false,
        hard_failure_reason: None,
        transient_failure_reason: Some(reason.to_owned()),
    }
}

const fn generic_alert_for_push_kind(push_kind: PushKind) -> Option<GenericAlert<'static>> {
    match push_kind {
        PushKind::Message => Some(GenericAlert {
            title: "TellMe",
            body: "New secure message",
        }),
        PushKind::Other => Some(GenericAlert {
            title: "TellMe",
            body: "New secure activity",
        }),
        PushKind::Call | PushKind::CallMissed => None,
    }
}

fn provider_token_at(
    team_id: &str,
    key_id: &str,
    private_key_pem: &str,
    issued_at_sec: u64,
) -> Result<String, WorkerError> {
    let header = encode_json_segment(&ApnsJwtHeader {
        alg: APNS_AUTH_ALG,
        kid: key_id,
    })?;
    let claims = encode_json_segment(&ApnsJwtClaims {
        iss: team_id,
        iat: issued_at_sec,
    })?;
    let signing_input = format!("{header}.{claims}");
    let signature = sign_es256(private_key_pem, signing_input.as_bytes())?;
    Ok(format!("{signing_input}.{signature}"))
}

fn encode_json_segment<T: Serialize>(value: &T) -> Result<String, WorkerError> {
    let bytes = serde_json::to_vec(value).map_err(|_| WorkerError)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn sign_es256(private_key_pem: &str, input: &[u8]) -> Result<String, WorkerError> {
    let signing_key = signing_key(private_key_pem)?;
    let signature: Signature = signing_key.sign(input);
    Ok(URL_SAFE_NO_PAD.encode(signature.to_bytes()))
}

fn signing_key(private_key_pem: &str) -> Result<SigningKey, WorkerError> {
    SigningKey::from_pkcs8_pem(private_key_pem).map_err(|_| WorkerError)
}

fn apns_url(environment: PushEnvironment, token: &str) -> String {
    let host = match environment {
        PushEnvironment::Production => APNS_PRODUCTION_HOST,
        PushEnvironment::Sandbox => APNS_SANDBOX_HOST,
    };
    format!("https://{host}/3/device/{token}")
}

fn voip_collapse_id(sync_id: &str) -> String {
    format!("voip:{sync_id}").chars().take(64).collect()
}

fn current_epoch_sec() -> Result<u64, WorkerError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| WorkerError)
}

fn private_key_from_env() -> Result<String, WorkerError> {
    let base64_value = env::var("APNS_PRIVATE_KEY_BASE64")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    if let Some(value) = base64_value {
        let bytes = STANDARD.decode(value).map_err(|_| WorkerError)?;
        return String::from_utf8(bytes).map_err(|_| WorkerError);
    }

    let path = env::var("APNS_PRIVATE_KEY_PATH")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .ok_or(WorkerError)?;
    fs::read_to_string(path).map_err(|_| WorkerError)
}

fn required_env(name: &str) -> Result<String, WorkerError> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .ok_or(WorkerError)
}

fn optional_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn default_voip_topic(bundle_id: &str) -> String {
    format!("{bundle_id}.voip")
}

fn non_empty(value: &str) -> Result<String, WorkerError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(WorkerError)
    } else {
        Ok(trimmed.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        apns_failure_reason, provider_token_at, ApnsProviderConfig, ApnsPushProvider,
        DEFAULT_APNS_EXPIRY_SEC,
    };
    use crate::devices::PushMode;
    use crate::messages::{PushKind, WakeupClass};
    use crate::worker_service::ProviderPushRequest;
    use crate::workers::PushEnvironment;
    use p256::ecdsa::SigningKey;
    use p256::pkcs8::{EncodePrivateKey, LineEnding};
    use serde_json::Value;

    #[test]
    fn builds_privacy_first_background_request() {
        let Ok(provider) = test_provider() else {
            return;
        };
        let issued_at = 1_700_000_000;
        let result = provider.apns_request_at(
            &provider_request(PushMode::PrivacyFirst, Some(PushKind::Message)),
            issued_at,
        );

        assert!(result.is_ok());
        let Ok(request) = result else {
            return;
        };
        assert_eq!(
            request.url,
            "https://api.sandbox.push.apple.com/3/device/apns-token-1"
        );
        assert_eq!(request.apns_topic, "com.example.messenger");
        assert_eq!(request.apns_push_type, "background");
        assert_eq!(request.apns_priority, "5");
        assert_eq!(
            request.apns_expiration,
            (issued_at + DEFAULT_APNS_EXPIRY_SEC).to_string()
        );
        assert_eq!(request.apns_collapse_id, "sync:device-1");
        assert_jwt_shape(&request.authorization);

        let Ok(payload) = serde_json::from_str::<Value>(&request.body) else {
            return;
        };
        assert_eq!(
            payload.get("message_id").and_then(Value::as_str),
            Some("message-1")
        );
        assert_eq!(
            payload.get("device_id").and_then(Value::as_str),
            Some("device-1")
        );
        assert_eq!(
            payload.get("push_mode").and_then(Value::as_str),
            Some("privacy_first")
        );
        assert!(payload.get("push_kind").is_none());
        let Some(aps) = payload.get("aps").and_then(Value::as_object) else {
            return;
        };
        assert_eq!(
            aps.get("content-available").and_then(Value::as_u64),
            Some(1)
        );
        assert!(aps.get("alert").is_none());
        assert!(aps.get("sound").is_none());
    }

    #[test]
    fn builds_fast_notify_message_alert_without_identity_metadata() {
        let Ok(provider) = test_provider() else {
            return;
        };
        let result = provider.apns_request_at(
            &provider_request(PushMode::FastNotify, Some(PushKind::Message)),
            1_700_000_000,
        );

        assert!(result.is_ok());
        let Ok(request) = result else {
            return;
        };
        assert_eq!(request.apns_push_type, "alert");
        let Ok(payload) = serde_json::from_str::<Value>(&request.body) else {
            return;
        };
        assert_eq!(
            payload.get("push_kind").and_then(Value::as_str),
            Some("message")
        );
        assert!(payload.get("conversation_id").is_none());
        assert!(payload.get("sender_device_id").is_none());
        assert!(payload.get("sender_handle").is_none());

        let Some(aps) = payload.get("aps").and_then(Value::as_object) else {
            return;
        };
        assert_eq!(aps.get("mutable-content").and_then(Value::as_u64), Some(1));
        assert_eq!(aps.get("sound").and_then(Value::as_str), Some("default"));
        let Some(alert) = aps.get("alert").and_then(Value::as_object) else {
            return;
        };
        assert_eq!(alert.get("title").and_then(Value::as_str), Some("TellMe"));
        assert_eq!(
            alert.get("body").and_then(Value::as_str),
            Some("New secure message")
        );
    }

    #[test]
    fn suppresses_call_hints_even_when_provider_is_called_directly() {
        let Ok(provider) = test_provider() else {
            return;
        };
        let result = provider.apns_request_at(
            &provider_request(PushMode::FastNotify, Some(PushKind::CallMissed)),
            1_700_000_000,
        );

        assert!(result.is_ok());
        let Ok(request) = result else {
            return;
        };
        assert_eq!(request.apns_push_type, "background");
        let Ok(payload) = serde_json::from_str::<Value>(&request.body) else {
            return;
        };
        assert!(payload.get("push_kind").is_none());
        let Some(aps) = payload.get("aps").and_then(Value::as_object) else {
            return;
        };
        assert!(aps.get("alert").is_none());
        assert!(aps.get("sound").is_none());
    }

    #[test]
    fn builds_voip_opaque_payload_without_plaintext_call_metadata() {
        let Ok(provider) = test_provider() else {
            return;
        };
        let result = provider.apns_request_at(
            &provider_request_with_wakeup(
                PushMode::PrivacyFirst,
                Some(PushKind::Call),
                WakeupClass::VoipOpaque,
            ),
            1_700_000_000,
        );

        assert!(result.is_ok());
        let Ok(request) = result else {
            return;
        };
        assert_eq!(request.apns_topic, "com.example.messenger.voip");
        assert_eq!(request.apns_push_type, "voip");
        assert_eq!(request.apns_priority, "10");
        assert!(request.apns_collapse_id.starts_with("voip:message-1"));

        let Ok(payload) = serde_json::from_str::<Value>(&request.body) else {
            return;
        };
        assert_eq!(
            payload.get("wakeup_class").and_then(Value::as_str),
            Some("voip_opaque")
        );
        assert_eq!(
            payload.get("sync_id").and_then(Value::as_str),
            Some("message-1")
        );
        assert!(payload.get("device_id").is_none());
        assert!(payload.get("push_mode").is_none());
        assert!(payload.get("push_kind").is_none());
        assert!(payload.get("conversation_id").is_none());
        assert!(payload.get("call_id").is_none());
        assert!(payload.get("sender_handle").is_none());

        let Some(aps) = payload.get("aps").and_then(Value::as_object) else {
            return;
        };
        assert_eq!(
            aps.get("content-available").and_then(Value::as_u64),
            Some(1)
        );
        assert!(aps.get("alert").is_none());
        assert!(aps.get("sound").is_none());
    }

    #[test]
    fn signs_provider_token_as_three_segment_jwt() {
        let Some(private_key) = test_private_key() else {
            return;
        };
        let result = provider_token_at("TEAM123456", "KEY1234567", &private_key, 1_700_000_000);

        assert!(result.is_ok());
        let Ok(token) = result else {
            return;
        };
        assert_eq!(token.split('.').count(), 3);
        assert!(!token.contains(private_key.as_str()));
    }

    #[test]
    fn reads_apns_failure_reason_without_leaking_response_body() {
        assert_eq!(
            apns_failure_reason(r#"{"reason":"BadDeviceToken"}"#),
            Some("BadDeviceToken".to_owned())
        );
        assert_eq!(apns_failure_reason(r#"{"reason":""}"#), None);
        assert_eq!(apns_failure_reason("not-json"), None);
    }

    fn test_provider() -> Result<ApnsPushProvider, crate::worker_service::WorkerError> {
        let Some(private_key) = test_private_key() else {
            return Err(crate::worker_service::WorkerError);
        };

        ApnsProviderConfig::new(
            "com.example.messenger",
            "KEY1234567",
            "TEAM123456",
            &private_key,
            10_000,
        )
        .map(ApnsPushProvider::new)
    }

    fn test_private_key() -> Option<String> {
        let signing_key = SigningKey::from_slice(&[7_u8; 32]).ok()?;
        signing_key
            .to_pkcs8_pem(LineEnding::LF)
            .ok()
            .map(|pem| pem.to_string())
    }

    fn provider_request(push_mode: PushMode, push_kind: Option<PushKind>) -> ProviderPushRequest {
        provider_request_with_wakeup(push_mode, push_kind, WakeupClass::Generic)
    }

    fn provider_request_with_wakeup(
        push_mode: PushMode,
        push_kind: Option<PushKind>,
        wakeup_class: WakeupClass,
    ) -> ProviderPushRequest {
        ProviderPushRequest {
            token: "apns-token-1".to_owned(),
            push_environment: PushEnvironment::Sandbox,
            message_id: "message-1".to_owned(),
            device_id: "device-1".to_owned(),
            push_mode,
            push_kind,
            wakeup_class,
        }
    }

    fn assert_jwt_shape(authorization: &str) {
        let jwt = authorization.strip_prefix("bearer ");
        assert!(jwt.is_some());
        let Some(jwt) = jwt else {
            return;
        };
        assert_eq!(jwt.split('.').count(), 3);
    }
}
