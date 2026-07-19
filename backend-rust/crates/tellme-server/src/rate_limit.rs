//! Targeted fixed-window rate-limit policy.

use crate::session::TokenKind;

/// Rate-limit window length.
pub const RATE_LIMIT_WINDOW_MS: u64 = 60_000;

// Public limits stay conservative; authenticated high-volume paths are handled below by explicit bypass rules.
pub const AUTH_RATE_LIMIT_PER_MINUTE: u64 = 20;
pub const PUBLIC_DIRECTORY_RATE_LIMIT_PER_MINUTE: u64 = 60;
pub const FEDERATION_PREAUTH_RATE_LIMIT_PER_MINUTE: u64 = 60;
pub const FEDERATION_RATE_LIMIT_PER_MINUTE: u64 = 600;
pub const MEDIA_UPLOAD_INIT_RATE_LIMIT_PER_MINUTE: u64 = 30;
pub const MEDIA_UPLOAD_RATE_LIMIT_PER_MINUTE: u64 = 30;
pub const MEDIA_DOWNLOAD_RATE_LIMIT_PER_MINUTE: u64 = 120;

const IOS_E2E_BYPASS_PREFIX: &str = "ios1337";
const API_PREFIX: &str = "/api/";
const AUTH_REFRESH_PATH: &str = "/api/auth/refresh";
const HIGH_VOLUME_PREFIXES: &[&str] = &["/api/messages", "/api/sync", "/api/prekeys/get"];

/// Fixed-window counter state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CounterState {
    pub count: u64,
    pub reset_at_ms: u64,
}

/// Rate-limit decision after one request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RateLimitDecision {
    Allow(CounterState),
    Throttle(CounterState),
}

#[must_use]
pub fn normalize_key(raw: Option<&str>) -> Option<String> {
    let normalized = raw?.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

#[must_use]
pub const fn record_window_hit(
    current: Option<CounterState>,
    now_ms: u64,
    limit: u64,
) -> RateLimitDecision {
    let mut state = match current {
        Some(existing) if existing.reset_at_ms > now_ms => existing,
        _ => CounterState {
            count: 0,
            reset_at_ms: now_ms + RATE_LIMIT_WINDOW_MS,
        },
    };

    if state.count >= limit {
        return RateLimitDecision::Throttle(state);
    }

    state.count += 1;
    RateLimitDecision::Allow(state)
}

#[must_use]
pub fn normalized_path(path: &str) -> String {
    let candidate = path.trim().to_ascii_lowercase();
    let Some((without_query, _query)) = candidate.split_once('?') else {
        return candidate;
    };

    without_query.to_owned()
}

#[must_use]
pub fn is_api_path(path: &str) -> bool {
    normalized_path(path).starts_with(API_PREFIX)
}

#[must_use]
pub fn is_high_volume_authenticated_path(path: &str) -> bool {
    let normalized = normalized_path(path);
    HIGH_VOLUME_PREFIXES
        .iter()
        .any(|prefix| normalized.starts_with(prefix))
}

#[must_use]
pub fn is_media_path(path: &str) -> bool {
    normalized_path(path).starts_with("/api/media")
}

#[must_use]
pub fn bearer_token(authorization_header: Option<&str>) -> Option<String> {
    let token = authorization_header?.strip_prefix("Bearer ")?.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_owned())
    }
}

#[must_use]
pub fn has_ios_e2e_bypass_user_handle(user_handle: Option<&str>) -> bool {
    let Some(handle) = user_handle else {
        return false;
    };
    let parsed = handle.strip_prefix('@').unwrap_or(handle);
    let local = parsed
        .split_once(':')
        .map_or(parsed, |(local, _domain)| local);
    local
        .trim()
        .to_ascii_lowercase()
        .starts_with(IOS_E2E_BYPASS_PREFIX)
}

#[must_use]
pub fn bypass_for_session_claims(path: &str, token_type: TokenKind, user_handle: &str) -> bool {
    if has_ios_e2e_bypass_user_handle(Some(user_handle)) {
        return true;
    }

    if token_type != TokenKind::Session {
        return false;
    }

    (is_api_path(path) && !is_media_path(path)) || is_high_volume_authenticated_path(path)
}

#[must_use]
pub fn bypass_for_refresh_claims(path: &str, token_type: TokenKind) -> bool {
    normalized_path(path) == AUTH_REFRESH_PATH && token_type == TokenKind::Refresh
}

#[must_use]
pub const fn too_many_requests_status() -> u16 {
    429
}

#[must_use]
pub const fn too_many_requests_error() -> &'static str {
    "Too many requests"
}

#[cfg(test)]
mod tests {
    use super::{
        bearer_token, bypass_for_refresh_claims, bypass_for_session_claims,
        has_ios_e2e_bypass_user_handle, is_high_volume_authenticated_path, is_media_path,
        normalize_key, normalized_path, record_window_hit, too_many_requests_error,
        too_many_requests_status, CounterState, RateLimitDecision,
    };
    use crate::session::TokenKind;

    #[test]
    fn normalizes_keys_and_paths() {
        assert_eq!(
            normalize_key(Some(" Trusted.Example ")).as_deref(),
            Some("trusted.example")
        );
        assert_eq!(normalize_key(Some("  ")), None);
        assert_eq!(
            normalized_path(" /API/Messages/Send?x=1 "),
            "/api/messages/send"
        );
    }

    #[test]
    fn records_fixed_window_hits() {
        assert_eq!(
            record_window_hit(None, 1_000, 2),
            RateLimitDecision::Allow(CounterState {
                count: 1,
                reset_at_ms: 61_000,
            })
        );
        let state = CounterState {
            count: 2,
            reset_at_ms: 61_000,
        };
        assert_eq!(
            record_window_hit(Some(state), 2_000, 2),
            RateLimitDecision::Throttle(state)
        );
        assert_eq!(
            record_window_hit(Some(state), 61_000, 2),
            RateLimitDecision::Allow(CounterState {
                count: 1,
                reset_at_ms: 121_000,
            })
        );
    }

    #[test]
    fn detects_bearer_and_ios_e2e_bypass_handles() {
        assert_eq!(bearer_token(Some("Bearer token")).as_deref(), Some("token"));
        assert_eq!(bearer_token(Some("bearer token")), None);
        assert!(has_ios_e2e_bypass_user_handle(Some(
            "@ios1337alpha:localhost"
        )));
        assert!(has_ios_e2e_bypass_user_handle(Some(
            "ios1337alpha:localhost"
        )));
        assert!(!has_ios_e2e_bypass_user_handle(Some("@alice:localhost")));
    }

    #[test]
    fn keeps_media_routes_targeted_while_bypassing_authenticated_api_routes() {
        assert!(is_high_volume_authenticated_path("/api/messages/send"));
        assert!(is_high_volume_authenticated_path("/api/sync/stream"));
        assert!(is_media_path("/api/media/upload/init"));
        assert!(bypass_for_session_claims(
            "/api/messages/send",
            TokenKind::Session,
            "@alice:example.org"
        ));
        assert!(!bypass_for_session_claims(
            "/api/media/upload/init",
            TokenKind::Session,
            "@alice:example.org"
        ));
        assert!(bypass_for_session_claims(
            "/api/auth/register",
            TokenKind::Session,
            "@ios1337alpha:localhost"
        ));
    }

    #[test]
    fn bypasses_refresh_endpoint_only_for_refresh_tokens() {
        assert!(bypass_for_refresh_claims(
            "/api/auth/refresh",
            TokenKind::Refresh
        ));
        assert!(!bypass_for_refresh_claims(
            "/api/auth/register",
            TokenKind::Refresh
        ));
        assert!(!bypass_for_refresh_claims(
            "/api/auth/refresh",
            TokenKind::Session
        ));
        assert_eq!(too_many_requests_status(), 429);
        assert_eq!(too_many_requests_error(), "Too many requests");
    }
}
