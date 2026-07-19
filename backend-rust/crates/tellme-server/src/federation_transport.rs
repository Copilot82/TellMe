//! Outgoing federation HTTP transport for encrypted outbox deliveries.
//!
//! This boundary signs the same `x-mesh-*` request envelope as the TypeScript backend. It never inspects ciphertext
//! contents, never logs signing material, and strips call-oriented push hints before crossing federation boundaries.

use crate::federation::{
    canonical_federation_string, federation_base_url, FEDERATION_REQUEST_TIMEOUT_MS,
};
use crate::hashing::sha256_base64;
use crate::messages::{push_kind_for_job, DeliveryUnit};
use crate::worker_service::{OutboxDeliveryResult, WorkerError};
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine as _;
use ed25519_dalek::{Signer, SigningKey};
use reqwest::Client;
use serde::Serialize;
use std::env;
use std::time::Duration;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const FEDERATION_DELIVER_PATH: &str = "/federation/v1/deliver";
const DEFAULT_SERVER_DOMAIN: &str = "localhost";
const DEFAULT_SERVER_KEY_ID: &str = "ed25519:1";
const ED25519_PRIVATE_KEY_LENGTH: usize = 32;
const ED25519_PKCS8_PREFIX: [u8; 16] = [
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];

/// Runtime configuration for outgoing federation delivery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FederationTransportConfig {
    server_domain: String,
    key_id: String,
    private_key: String,
    timeout_ms: u64,
}

impl FederationTransportConfig {
    /// Creates explicit outgoing federation transport config.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when required string values are empty, timeout is zero, or the private key is invalid.
    pub fn new(
        server_domain: impl Into<String>,
        key_id: impl Into<String>,
        private_key: impl Into<String>,
        timeout_ms: u64,
    ) -> Result<Self, WorkerError> {
        let server_domain = server_domain.into();
        let key_id = key_id.into();
        let private_key = private_key.into();
        let config = Self {
            server_domain: non_empty(&server_domain)?,
            key_id: non_empty(&key_id)?,
            private_key: non_empty(&private_key)?,
            timeout_ms,
        };
        if config.timeout_ms == 0 {
            return Err(WorkerError);
        }
        private_seed_bytes(&config.private_key)?;
        Ok(config)
    }

    /// Creates outgoing federation transport config from the current server env contract.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when `SERVER_SIGN_PRIVATE_KEY` is missing/invalid or numeric env values are invalid.
    pub fn from_env() -> Result<Self, WorkerError> {
        let timeout_ms = env::var("FEDERATION_REQUEST_TIMEOUT_MS")
            .ok()
            .map(|value| value.parse::<u64>())
            .transpose()
            .map_err(|_| WorkerError)?
            .unwrap_or(FEDERATION_REQUEST_TIMEOUT_MS);

        Self::new(
            env::var("SERVER_DOMAIN").unwrap_or_else(|_| DEFAULT_SERVER_DOMAIN.to_owned()),
            env::var("SERVER_SIGN_KEY_ID").unwrap_or_else(|_| DEFAULT_SERVER_KEY_ID.to_owned()),
            env::var("SERVER_SIGN_PRIVATE_KEY").map_err(|_| WorkerError)?,
            timeout_ms,
        )
    }

    #[must_use]
    pub fn server_domain(&self) -> &str {
        &self.server_domain
    }

    #[must_use]
    pub fn key_id(&self) -> &str {
        &self.key_id
    }

    #[must_use]
    pub const fn timeout(&self) -> Duration {
        Duration::from_millis(self.timeout_ms)
    }
}

/// Signed outgoing federation deliver request ready for HTTP transmission.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedFederationDeliverRequest {
    pub url: String,
    pub body: String,
    pub x_mesh_server: String,
    pub x_mesh_key_id: String,
    pub x_mesh_date: String,
    pub x_mesh_signature: String,
    pub x_mesh_body_sha256: String,
}

/// HTTPS transport for remote federation outbox jobs.
#[derive(Debug, Clone)]
pub struct FederationHttpTransport {
    config: FederationTransportConfig,
    client: Client,
}

impl FederationHttpTransport {
    /// Creates a federation HTTP transport from explicit config.
    #[must_use]
    pub fn new(config: FederationTransportConfig) -> Self {
        Self {
            config,
            client: Client::new(),
        }
    }

    /// Creates a federation HTTP transport from environment variables.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when config cannot be loaded.
    pub fn from_env() -> Result<Self, WorkerError> {
        FederationTransportConfig::from_env().map(Self::new)
    }

    /// Sends encrypted deliveries to a remote federation server.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when request construction or response-body reading fails.
    pub async fn deliver(
        &self,
        to_server: &str,
        deliveries: &[DeliveryUnit],
    ) -> Result<OutboxDeliveryResult, WorkerError> {
        let request = self.signed_deliver_request(to_server, deliveries)?;
        let response = self
            .client
            .post(&request.url)
            .timeout(self.config.timeout())
            .header("content-type", "application/json")
            .header("x-mesh-server", request.x_mesh_server)
            .header("x-mesh-key-id", request.x_mesh_key_id)
            .header("x-mesh-date", request.x_mesh_date)
            .header("x-mesh-signature", request.x_mesh_signature)
            .header("x-mesh-body-sha256", request.x_mesh_body_sha256)
            .body(request.body)
            .send()
            .await;

        let Ok(response) = response else {
            return Ok(OutboxDeliveryResult {
                ok: false,
                status: 0,
                body: "Federation transport error".to_owned(),
            });
        };
        let ok = response.status().is_success();
        let status = i32::from(response.status().as_u16());
        let body = response.text().await.map_err(|_| WorkerError)?;

        Ok(OutboxDeliveryResult { ok, status, body })
    }

    /// Builds the signed deliver request without sending it.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when JSON serialization, signing, or date formatting fails.
    pub fn signed_deliver_request(
        &self,
        to_server: &str,
        deliveries: &[DeliveryUnit],
    ) -> Result<SignedFederationDeliverRequest, WorkerError> {
        self.signed_deliver_request_at(to_server, deliveries, &current_x_mesh_date()?)
    }

    fn signed_deliver_request_at(
        &self,
        to_server: &str,
        deliveries: &[DeliveryUnit],
        x_mesh_date: &str,
    ) -> Result<SignedFederationDeliverRequest, WorkerError> {
        let remote = non_empty(to_server)?;
        let deliveries = sanitized_deliveries(deliveries);
        let payload = FederationDeliverPayload {
            from_server: self.config.server_domain(),
            deliveries: &deliveries,
        };
        let body = serde_json::to_string(&payload).map_err(|_| WorkerError)?;
        let signature = sign_federation_request(
            "POST",
            FEDERATION_DELIVER_PATH,
            x_mesh_date,
            &body,
            &self.config.private_key,
        )?;

        Ok(SignedFederationDeliverRequest {
            url: format!(
                "{}{}",
                federation_base_url(&remote),
                FEDERATION_DELIVER_PATH
            ),
            body: body.clone(),
            x_mesh_server: self.config.server_domain().to_owned(),
            x_mesh_key_id: self.config.key_id().to_owned(),
            x_mesh_date: x_mesh_date.to_owned(),
            x_mesh_signature: signature,
            x_mesh_body_sha256: sha256_base64(body.as_bytes()),
        })
    }
}

#[derive(Debug, Clone, Copy, Serialize)]
struct FederationDeliverPayload<'a> {
    from_server: &'a str,
    deliveries: &'a [DeliveryUnit],
}

/// Signs one federation request with server `Ed25519` private key material.
///
/// # Errors
///
/// Returns `WorkerError` when the private key material cannot be decoded.
pub fn sign_federation_request(
    method: &str,
    path: &str,
    x_mesh_date: &str,
    body_raw: &str,
    private_key: &str,
) -> Result<String, WorkerError> {
    let seed = private_seed_bytes(private_key)?;
    let signing_key = SigningKey::from_bytes(&seed);
    let canonical = canonical_federation_string(method, path, x_mesh_date, body_raw);
    let signature = signing_key.sign(canonical.as_bytes());

    Ok(STANDARD.encode(signature.to_bytes()))
}

fn sanitized_deliveries(deliveries: &[DeliveryUnit]) -> Vec<DeliveryUnit> {
    deliveries
        .iter()
        .map(|delivery| {
            let mut sanitized = delivery.clone();
            sanitized.push_kind = push_kind_for_job(true, delivery.push_kind);
            sanitized
        })
        .collect()
}

fn current_x_mesh_date() -> Result<String, WorkerError> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|_| WorkerError)
}

fn non_empty(value: &str) -> Result<String, WorkerError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(WorkerError);
    }

    Ok(trimmed.to_owned())
}

fn private_seed_bytes(value: &str) -> Result<[u8; ED25519_PRIVATE_KEY_LENGTH], WorkerError> {
    let decoded = decode_private_key_material(value)?;
    if decoded.len() == ED25519_PRIVATE_KEY_LENGTH {
        return decoded.as_slice().try_into().map_err(|_| WorkerError);
    }

    let Some(seed) = decoded.as_slice().strip_prefix(&ED25519_PKCS8_PREFIX) else {
        return Err(WorkerError);
    };
    if seed.len() != ED25519_PRIVATE_KEY_LENGTH {
        return Err(WorkerError);
    }

    seed.try_into().map_err(|_| WorkerError)
}

fn decode_private_key_material(value: &str) -> Result<Vec<u8>, WorkerError> {
    let trimmed = value.trim();
    let pem_marker = concat!("BEGIN ", "PRIVATE KEY");
    if trimmed.contains(pem_marker) {
        let body = trimmed
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with("-----"))
            .collect::<String>();
        return decode_base64_or_url(&body);
    }

    decode_base64_or_url(trimmed)
}

fn decode_base64_or_url(value: &str) -> Result<Vec<u8>, WorkerError> {
    for engine in [&STANDARD, &STANDARD_NO_PAD, &URL_SAFE, &URL_SAFE_NO_PAD] {
        if let Ok(decoded) = engine.decode(value) {
            return Ok(decoded);
        }
    }

    Err(WorkerError)
}

#[cfg(test)]
mod tests {
    use super::{sign_federation_request, FederationHttpTransport, FederationTransportConfig};
    use crate::federation::{body_hash_matches, verify_federation_signature};
    use crate::messages::{DeliveryUnit, PushKind};
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine as _;
    use ed25519_dalek::SigningKey;

    const DATE: &str = "2026-02-26T12:00:00.000Z";

    #[test]
    fn signs_federation_request_with_typescript_compatible_material() {
        let key = SigningKey::from_bytes(&[7; 32]);
        let private_key = STANDARD.encode([7; 32]);
        let public_key = STANDARD.encode(key.verifying_key().to_bytes());
        let body = r#"{"from_server":"local.example","deliveries":[]}"#;

        let signature =
            sign_federation_request("POST", "/federation/v1/deliver", DATE, body, &private_key);

        assert!(signature.is_ok());
        let Ok(signature) = signature else {
            return;
        };
        assert!(verify_federation_signature(
            "POST",
            "/federation/v1/deliver",
            DATE,
            body,
            &signature,
            &public_key
        ));
    }

    #[test]
    fn builds_signed_deliver_request_and_suppresses_call_push_kind() {
        let config = FederationTransportConfig::new(
            "local.example",
            "ed25519:test",
            STANDARD.encode([7; 32]),
            5_000,
        );
        assert!(config.is_ok());
        let Ok(config) = config else {
            return;
        };
        let transport = FederationHttpTransport::new(config);
        let request =
            transport.signed_deliver_request_at("remote.example", &[call_delivery()], DATE);

        assert!(request.is_ok());
        let Ok(request) = request else {
            return;
        };
        assert_eq!(request.url, "https://remote.example/federation/v1/deliver");
        assert_eq!(request.x_mesh_server, "local.example");
        assert_eq!(request.x_mesh_key_id, "ed25519:test");
        assert!(body_hash_matches(
            &request.x_mesh_body_sha256,
            &request.body
        ));
        assert!(!request.body.contains("\"push_kind\":\"call\""));
        assert!(request.body.contains("\"push_kind\":null"));
    }

    #[test]
    fn rejects_empty_or_invalid_transport_config() {
        assert_eq!(
            FederationTransportConfig::new("", "ed25519:test", STANDARD.encode([7; 32]), 5_000),
            Err(crate::worker_service::WorkerError)
        );
        assert_eq!(
            FederationTransportConfig::new("local.example", "ed25519:test", "bad-key", 5_000),
            Err(crate::worker_service::WorkerError)
        );
        assert_eq!(
            FederationTransportConfig::new(
                "local.example",
                "ed25519:test",
                STANDARD.encode([7; 32]),
                0
            ),
            Err(crate::worker_service::WorkerError)
        );
    }

    fn call_delivery() -> DeliveryUnit {
        DeliveryUnit {
            wire_version: 2,
            delivery_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            to_server: "remote.example".to_owned(),
            to_user: "@bob:remote.example".to_owned(),
            to_device_id: "ios-primary".to_owned(),
            message_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            timestamp: "2026-03-01T00:00:00.000Z".to_owned(),
            ttl_sec: 600,
            ciphertext_blob: "opaque-ciphertext".to_owned(),
            push_kind: Some(PushKind::Call),
            wakeup_class: None,
        }
    }
}
