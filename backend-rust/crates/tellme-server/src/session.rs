//! Session-token contract for `TellMe` v2 auth middleware.
//!
//! The current TypeScript backend signs `HS256` `JWTs` with separate session and refresh secrets. This module mirrors
//! that wire contract while keeping token-store lookups as a later database integration step.

use crate::hashing::sha256_hex;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::env;
use std::error::Error;
use std::fmt::{Debug, Display, Formatter};

const DEFAULT_SESSION_TTL_SEC: u64 = 900;
const DEFAULT_REFRESH_TTL_SEC: u64 = 60 * 60 * 24 * 30;
const JWT_HEADER_B64: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

type HmacSha256 = Hmac<Sha256>;

/// Token type embedded in signed claims.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TokenKind {
    Session,
    Refresh,
}

/// Session subject fields shared by session and refresh token creation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenSubject {
    account_id: String,
    user_handle: String,
    device_id: String,
    session_id: String,
}

impl TokenSubject {
    #[must_use]
    pub const fn new(
        account_id: String,
        user_handle: String,
        device_id: String,
        session_id: String,
    ) -> Self {
        Self {
            account_id,
            user_handle,
            device_id,
            session_id,
        }
    }

    #[must_use]
    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    #[must_use]
    pub fn user_handle(&self) -> &str {
        &self.user_handle
    }

    #[must_use]
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }
}

/// Verified token claims.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionClaims {
    #[serde(rename = "accountId")]
    account_id: String,
    #[serde(rename = "userHandle")]
    user_handle: String,
    #[serde(rename = "deviceId")]
    device_id: String,
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(rename = "tokenType")]
    token_type: TokenKind,
    iat: u64,
    exp: u64,
}

impl SessionClaims {
    #[must_use]
    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    #[must_use]
    pub fn user_handle(&self) -> &str {
        &self.user_handle
    }

    #[must_use]
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    #[must_use]
    pub const fn token_type(&self) -> TokenKind {
        self.token_type
    }

    #[must_use]
    pub const fn issued_at_sec(&self) -> u64 {
        self.iat
    }

    #[must_use]
    pub const fn expires_at_sec(&self) -> u64 {
        self.exp
    }
}

/// Session token configuration. Secrets are redacted from `Debug` output.
#[derive(Clone, PartialEq, Eq)]
pub struct TokenConfig {
    session_secret: String,
    refresh_secret: String,
    session_ttl_sec: u64,
    refresh_ttl_sec: u64,
}

impl TokenConfig {
    /// Loads session token configuration from environment variables.
    ///
    /// # Errors
    ///
    /// Returns an error when required secrets are missing or TTL values are invalid.
    pub fn from_env() -> Result<Self, TokenError> {
        Ok(Self::new(
            required_env("JWT_SECRET")?,
            required_env("JWT_REFRESH_SECRET")?,
            read_ttl_env("SESSION_TOKEN_TTL_SEC", DEFAULT_SESSION_TTL_SEC)?,
            read_ttl_env("REFRESH_TOKEN_TTL_SEC", DEFAULT_REFRESH_TTL_SEC)?,
        ))
    }

    #[must_use]
    pub const fn new(
        session_secret: String,
        refresh_secret: String,
        session_ttl_sec: u64,
        refresh_ttl_sec: u64,
    ) -> Self {
        Self {
            session_secret,
            refresh_secret,
            session_ttl_sec,
            refresh_ttl_sec,
        }
    }

    #[must_use]
    pub fn session_secret(&self) -> &str {
        &self.session_secret
    }

    #[must_use]
    pub fn refresh_secret(&self) -> &str {
        &self.refresh_secret
    }

    #[must_use]
    pub const fn session_ttl_sec(&self) -> u64 {
        self.session_ttl_sec
    }

    #[must_use]
    pub const fn refresh_ttl_sec(&self) -> u64 {
        self.refresh_ttl_sec
    }
}

impl Debug for TokenConfig {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TokenConfig")
            .field("session_secret", &"<redacted>")
            .field("refresh_secret", &"<redacted>")
            .field("session_ttl_sec", &self.session_ttl_sec)
            .field("refresh_ttl_sec", &self.refresh_ttl_sec)
            .finish()
    }
}

/// Session-token contract error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenError {
    MissingSecret(&'static str),
    InvalidTtl { name: &'static str, value: String },
    InvalidToken,
    InvalidJson,
}

impl Display for TokenError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingSecret(name) => write!(formatter, "{name} is required"),
            Self::InvalidTtl { name, value } => {
                write!(formatter, "invalid token ttl env {name}: {value}")
            }
            Self::InvalidToken => formatter.write_str("invalid token"),
            Self::InvalidJson => formatter.write_str("invalid token json"),
        }
    }
}

impl Error for TokenError {}

#[must_use]
pub const fn default_session_ttl_sec() -> u64 {
    DEFAULT_SESSION_TTL_SEC
}

#[must_use]
pub const fn default_refresh_ttl_sec() -> u64 {
    DEFAULT_REFRESH_TTL_SEC
}

/// Signs a session token with the same `HS256` `JWT` shape as the TypeScript backend.
///
/// # Errors
///
/// Returns an error if claim serialization fails.
pub fn sign_session_token(
    subject: &TokenSubject,
    config: &TokenConfig,
    issued_at_sec: u64,
) -> Result<String, TokenError> {
    sign_token(
        subject,
        TokenKind::Session,
        config.session_secret(),
        issued_at_sec,
        config.session_ttl_sec(),
    )
}

/// Signs a refresh token with the same `HS256` `JWT` shape as the TypeScript backend.
///
/// # Errors
///
/// Returns an error if claim serialization fails.
pub fn sign_refresh_token(
    subject: &TokenSubject,
    config: &TokenConfig,
    issued_at_sec: u64,
) -> Result<String, TokenError> {
    sign_token(
        subject,
        TokenKind::Refresh,
        config.refresh_secret(),
        issued_at_sec,
        config.refresh_ttl_sec(),
    )
}

/// Verifies a session-secret signed token and returns claims, or `None` for invalid/expired tokens.
#[must_use]
pub fn verify_session_token(
    token: &str,
    config: &TokenConfig,
    now_sec: u64,
) -> Option<SessionClaims> {
    verify_token(token, config.session_secret(), now_sec)
}

/// Verifies a refresh-secret signed token and returns claims, or `None` for invalid/expired tokens.
#[must_use]
pub fn verify_refresh_token(
    token: &str,
    config: &TokenConfig,
    now_sec: u64,
) -> Option<SessionClaims> {
    verify_token(token, config.refresh_secret(), now_sec)
}

#[must_use]
pub fn bearer_token(authorization_header: &str) -> Option<&str> {
    authorization_header.strip_prefix("Bearer ")
}

#[must_use]
pub fn token_hash(token: &str) -> String {
    sha256_hex(token.as_bytes())
}

fn sign_token(
    subject: &TokenSubject,
    token_type: TokenKind,
    secret: &str,
    issued_at_sec: u64,
    ttl_sec: u64,
) -> Result<String, TokenError> {
    let claims = SessionClaims {
        account_id: subject.account_id.clone(),
        user_handle: subject.user_handle.clone(),
        device_id: subject.device_id.clone(),
        session_id: subject.session_id.clone(),
        token_type,
        iat: issued_at_sec,
        exp: issued_at_sec.saturating_add(ttl_sec),
    };
    let payload = serde_json::to_vec(&claims).map_err(|_| TokenError::InvalidJson)?;
    let payload_b64 = URL_SAFE_NO_PAD.encode(payload);
    let signing_input = format!("{JWT_HEADER_B64}.{payload_b64}");
    let signature = hmac_sha256(secret, signing_input.as_bytes())?;

    Ok(format!(
        "{signing_input}.{}",
        URL_SAFE_NO_PAD.encode(signature)
    ))
}

fn verify_token(token: &str, secret: &str, now_sec: u64) -> Option<SessionClaims> {
    let (signing_input, signature_b64) = token.rsplit_once('.')?;
    let (header_b64, payload_b64) = signing_input.split_once('.')?;

    if header_b64 != JWT_HEADER_B64 {
        return None;
    }

    if !signature_valid(secret, signing_input.as_bytes(), signature_b64) {
        return None;
    }

    let Ok(payload_bytes) = URL_SAFE_NO_PAD.decode(payload_b64) else {
        return None;
    };
    let Ok(claims) = serde_json::from_slice::<SessionClaims>(&payload_bytes) else {
        return None;
    };

    if claims.exp <= now_sec {
        return None;
    }

    Some(claims)
}

fn signature_valid(secret: &str, signing_input: &[u8], signature_b64: &str) -> bool {
    let Ok(signature) = URL_SAFE_NO_PAD.decode(signature_b64) else {
        return false;
    };
    let Ok(mut mac) = HmacSha256::new_from_slice(secret.as_bytes()) else {
        return false;
    };
    mac.update(signing_input);
    mac.verify_slice(&signature).is_ok()
}

fn hmac_sha256(secret: &str, input: &[u8]) -> Result<Vec<u8>, TokenError> {
    let mut mac =
        HmacSha256::new_from_slice(secret.as_bytes()).map_err(|_| TokenError::InvalidToken)?;
    mac.update(input);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn required_env(name: &'static str) -> Result<String, TokenError> {
    let value = env::var(name).map_err(|_| TokenError::MissingSecret(name))?;
    if value.trim().is_empty() {
        return Err(TokenError::MissingSecret(name));
    }

    Ok(value)
}

fn read_ttl_env(name: &'static str, fallback: u64) -> Result<u64, TokenError> {
    let Ok(value) = env::var(name) else {
        return Ok(fallback);
    };
    if value.trim().is_empty() {
        return Ok(fallback);
    }

    value
        .parse::<u64>()
        .map_err(|_| TokenError::InvalidTtl { name, value })
}

#[cfg(test)]
mod tests {
    use super::{
        bearer_token, sign_refresh_token, sign_session_token, token_hash, verify_refresh_token,
        verify_session_token, SessionClaims, TokenConfig, TokenKind, TokenSubject,
    };

    const SESSION_SECRET: &str = "unit-test-session-secret";
    const REFRESH_SECRET: &str = "unit-test-refresh-secret";
    const FIXED_IAT: u64 = 1_700_000_000;
    const TS_SESSION_TOKEN: &str = concat!(
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.",
        "eyJhY2NvdW50SWQiOiJhY2MtMSIsInVzZXJIYW5kbGUiOiJAYWxpY2U6ZXhhbXBsZS5vcmciLCJkZXZpY2",
        "VJZCI6Imlvcy1wcmltYXJ5Iiwic2Vzc2lvbklkIjoic2Vzcy0xIiwidG9rZW5UeXBlIjoic2Vzc2lv",
        "biIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxNzAwMDAwOTAwfQ.",
        "zHZg71acrB9F6j35nOKVaKDU8iqPLQ1T72G2tg6zlvc"
    );
    const TS_REFRESH_TOKEN: &str = concat!(
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.",
        "eyJhY2NvdW50SWQiOiJhY2MtMSIsInVzZXJIYW5kbGUiOiJAYWxpY2U6ZXhhbXBsZS5vcmciLCJkZXZpY2",
        "VJZCI6Imlvcy1wcmltYXJ5Iiwic2Vzc2lvbklkIjoic2Vzcy0xIiwidG9rZW5UeXBlIjoicmVmcmVz",
        "aCIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxNzAwMDg2NDAwfQ.",
        "RaQH4SXNdGwV6zHnQCJPLNo-LLR1mxPHGHWtiAFa0ag"
    );

    #[test]
    fn signs_tokens_matching_typescript_jsonwebtoken_vectors() {
        let config = config();
        let subject = subject();

        let session = sign_session_token(&subject, &config, FIXED_IAT);
        let refresh = sign_refresh_token(&subject, &config, FIXED_IAT);

        assert_eq!(session.as_deref(), Ok(TS_SESSION_TOKEN));
        assert_eq!(refresh.as_deref(), Ok(TS_REFRESH_TOKEN));
    }

    #[test]
    fn verifies_typescript_session_and_refresh_vectors() {
        let config = config();

        let session = verify_session_token(TS_SESSION_TOKEN, &config, FIXED_IAT + 1);
        assert!(session.is_some());
        let Some(session_claims) = session else {
            return;
        };
        assert_claims(&session_claims, TokenKind::Session, FIXED_IAT + 900);

        let refresh = verify_refresh_token(TS_REFRESH_TOKEN, &config, FIXED_IAT + 1);
        assert!(refresh.is_some());
        let Some(refresh_claims) = refresh else {
            return;
        };
        assert_claims(&refresh_claims, TokenKind::Refresh, FIXED_IAT + 86_400);
    }

    #[test]
    fn rejects_expired_or_wrong_secret_tokens() {
        let config = config();

        let expired = verify_session_token(TS_SESSION_TOKEN, &config, FIXED_IAT + 900);
        assert_eq!(expired, None);

        let wrong_secret_config = TokenConfig::new(
            "wrong-session-secret".to_owned(),
            REFRESH_SECRET.to_owned(),
            900,
            86_400,
        );
        let invalid = verify_session_token(TS_SESSION_TOKEN, &wrong_secret_config, FIXED_IAT + 1);
        assert_eq!(invalid, None);
    }

    #[test]
    fn extracts_bearer_token_like_express_middleware() {
        assert_eq!(bearer_token("Bearer abc.def.ghi"), Some("abc.def.ghi"));
        assert_eq!(bearer_token("bearer abc.def.ghi"), None);
        assert_eq!(bearer_token("abc.def.ghi"), None);
    }

    #[test]
    fn hashes_tokens_for_session_store_lookup() {
        assert_eq!(
            token_hash("session-token"),
            "c101e911469c969171040b50d70543313cf968fdef5bacc780776f8fb399ab36"
        );
    }

    fn config() -> TokenConfig {
        TokenConfig::new(
            SESSION_SECRET.to_owned(),
            REFRESH_SECRET.to_owned(),
            900,
            86_400,
        )
    }

    fn subject() -> TokenSubject {
        TokenSubject::new(
            "acc-1".to_owned(),
            "@alice:example.org".to_owned(),
            "ios-primary".to_owned(),
            "sess-1".to_owned(),
        )
    }

    fn assert_claims(claims: &SessionClaims, token_type: TokenKind, exp: u64) {
        assert_eq!(claims.account_id(), "acc-1");
        assert_eq!(claims.user_handle(), "@alice:example.org");
        assert_eq!(claims.device_id(), "ios-primary");
        assert_eq!(claims.session_id(), "sess-1");
        assert_eq!(claims.token_type(), token_type);
        assert_eq!(claims.issued_at_sec(), FIXED_IAT);
        assert_eq!(claims.expires_at_sec(), exp);
    }
}
