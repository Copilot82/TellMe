//! Background worker contract helpers.

use crate::devices::{PushMode, PushTokenKind};
use crate::hashing::sha256_hex;
use crate::messages::{push_kind_for_job, PushKind, WakeupClass};

/// Default outbox worker interval.
pub const OUTBOX_WORKER_INTERVAL_MS: u64 = 5_000;

/// Default push worker interval.
pub const PUSH_WORKER_INTERVAL_MS: u64 = 2_000;

/// Batch size reserved by push and outbox workers.
pub const WORKER_RESERVE_LIMIT: u64 = 50;

/// Maximum retry delay used by job failure backoff.
pub const MAX_RETRY_DELAY_SEC: u64 = 300;

/// Minimum retry delay used by job failure backoff.
pub const MIN_RETRY_DELAY_SEC: u64 = 5;

/// APNs push environment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushEnvironment {
    Sandbox,
    Production,
}

impl PushEnvironment {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Sandbox => "sandbox",
            Self::Production => "production",
        }
    }
}

/// Push send request shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushSendRequest {
    pub push_environment: PushEnvironment,
    pub push_mode: PushMode,
    pub push_kind: Option<PushKind>,
    pub wakeup_class: WakeupClass,
}

/// Worker-level job completion decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobDecision {
    MarkSent { outcome: Option<&'static str> },
    MarkFailed { error: String },
}

#[must_use]
pub const fn retry_delay_sec(attempts: u32) -> u64 {
    let exponential = if attempts >= 63 {
        u64::MAX
    } else {
        1_u64 << attempts
    };

    if exponential < MIN_RETRY_DELAY_SEC {
        MIN_RETRY_DELAY_SEC
    } else if exponential > MAX_RETRY_DELAY_SEC {
        MAX_RETRY_DELAY_SEC
    } else {
        exponential
    }
}

#[must_use]
pub fn retry_soon_delay_sec(delay_sec: i64) -> u64 {
    if delay_sec < 1 {
        return 1;
    }

    let Ok(unsigned) = u64::try_from(delay_sec) else {
        return 1;
    };
    unsigned.clamp(1, MAX_RETRY_DELAY_SEC)
}

#[must_use]
pub fn resolve_push_environment(value: Option<&str>) -> PushEnvironment {
    match value {
        Some("production") => PushEnvironment::Production,
        _ => PushEnvironment::Sandbox,
    }
}

#[must_use]
pub const fn opposite_push_environment(value: PushEnvironment) -> PushEnvironment {
    match value {
        PushEnvironment::Production => PushEnvironment::Sandbox,
        PushEnvironment::Sandbox => PushEnvironment::Production,
    }
}

#[must_use]
pub fn is_hard_apns_failure(reason: Option<&str>) -> bool {
    matches!(
        reason,
        Some("BadDeviceToken" | "DeviceTokenNotForTopic" | "TopicDisallowed" | "Unregistered")
    )
}

#[must_use]
pub fn is_likely_wrong_push_environment(reason: Option<&str>) -> bool {
    matches!(reason, Some("BadDeviceToken" | "DeviceTokenNotForTopic"))
}

#[must_use]
pub fn push_token_log_hash(token: &str) -> String {
    sha256_hex(token.as_bytes()).chars().take(16).collect()
}

#[must_use]
pub fn push_collapse_id(device_id: &str) -> String {
    format!("sync:{device_id}").chars().take(64).collect()
}

#[must_use]
pub const fn push_token_accepts_wakeup(
    token_kind: PushTokenKind,
    wakeup_class: WakeupClass,
) -> bool {
    matches!(
        (token_kind, wakeup_class),
        (PushTokenKind::Alert, WakeupClass::Generic)
            | (PushTokenKind::Voip, WakeupClass::VoipOpaque)
    )
}

#[must_use]
pub fn should_skip_sender_device(from_device_id: Option<&str>, owner_device_id: &str) -> bool {
    from_device_id.is_some_and(|from_device| from_device == owner_device_id)
}

#[must_use]
pub const fn push_send_request(
    push_environment: PushEnvironment,
    token_push_mode: PushMode,
    job_push_kind: Option<PushKind>,
    job_wakeup_class: WakeupClass,
) -> PushSendRequest {
    let allowed_fast_notify = matches!(token_push_mode, PushMode::FastNotify);
    PushSendRequest {
        push_environment,
        push_mode: token_push_mode,
        push_kind: push_kind_for_job(allowed_fast_notify, job_push_kind),
        wakeup_class: job_wakeup_class,
    }
}

#[must_use]
pub fn missing_push_tokens_decision(wakeup_class: WakeupClass) -> JobDecision {
    match wakeup_class {
        WakeupClass::Generic => JobDecision::MarkSent {
            outcome: Some("skipped_no_tokens"),
        },
        WakeupClass::VoipOpaque => JobDecision::MarkFailed {
            error: "missing_voip_token".to_owned(),
        },
    }
}

#[must_use]
pub fn outbox_decision(delivery_count: usize, ok: bool, status: i32, body: &str) -> JobDecision {
    if delivery_count == 0 || ok {
        return JobDecision::MarkSent { outcome: None };
    }

    let error = if status > 0 {
        format!("HTTP {status}: {body}")
    } else {
        body.to_owned()
    };

    JobDecision::MarkFailed { error }
}

#[must_use]
pub fn push_completion_decision(delivered: bool, transient_error: Option<&str>) -> JobDecision {
    if delivered {
        return JobDecision::MarkSent { outcome: None };
    }

    transient_error.map_or(
        JobDecision::MarkSent {
            outcome: Some("completed_without_delivery"),
        },
        |error| JobDecision::MarkFailed {
            error: error.to_owned(),
        },
    )
}

#[must_use]
pub fn should_remove_ciphertext_for_cleanup(
    status: &str,
    storage_bucket: Option<&str>,
    storage_key: Option<&str>,
) -> bool {
    status == "uploaded_verified"
        && storage_bucket.is_some_and(|value| !value.is_empty())
        && storage_key.is_some_and(|value| !value.is_empty())
}

#[must_use]
pub const fn should_delete_media_metadata(
    ciphertext_delete_required: bool,
    ciphertext_delete_ok: bool,
) -> bool {
    !ciphertext_delete_required || ciphertext_delete_ok
}

#[cfg(test)]
mod tests {
    use super::{
        is_hard_apns_failure, is_likely_wrong_push_environment, missing_push_tokens_decision,
        opposite_push_environment, outbox_decision, push_collapse_id, push_completion_decision,
        push_send_request, push_token_accepts_wakeup, push_token_log_hash,
        resolve_push_environment, retry_delay_sec, retry_soon_delay_sec,
        should_delete_media_metadata, should_remove_ciphertext_for_cleanup,
        should_skip_sender_device, JobDecision, PushEnvironment,
    };
    use crate::devices::{PushMode, PushTokenKind};
    use crate::messages::{PushKind, WakeupClass};

    #[test]
    fn computes_worker_retry_delays() {
        assert_eq!(retry_delay_sec(0), 5);
        assert_eq!(retry_delay_sec(3), 8);
        assert_eq!(retry_delay_sec(20), 300);
        assert_eq!(retry_soon_delay_sec(-2), 1);
        assert_eq!(retry_soon_delay_sec(301), 300);
        assert_eq!(retry_soon_delay_sec(42), 42);
    }

    #[test]
    fn resolves_push_environments_and_failures() {
        assert_eq!(
            resolve_push_environment(Some("production")),
            PushEnvironment::Production
        );
        assert_eq!(
            resolve_push_environment(Some("sandbox")),
            PushEnvironment::Sandbox
        );
        assert_eq!(
            opposite_push_environment(PushEnvironment::Production),
            PushEnvironment::Sandbox
        );
        assert!(is_hard_apns_failure(Some("BadDeviceToken")));
        assert!(is_hard_apns_failure(Some("Unregistered")));
        assert!(is_likely_wrong_push_environment(Some(
            "DeviceTokenNotForTopic"
        )));
        assert!(!is_likely_wrong_push_environment(Some("Unregistered")));
    }

    #[test]
    fn hashes_push_tokens_and_bounds_collapse_id() {
        assert_eq!(push_token_log_hash("push-token-1"), "2d38d7e01a6bb951");
        let long_device = "device-id-".repeat(20);
        assert_eq!(push_collapse_id(&long_device).len(), 64);
        assert!(push_collapse_id("dev-a").starts_with("sync:dev-a"));
    }

    #[test]
    fn keeps_push_payload_privacy() {
        assert!(should_skip_sender_device(Some("dev-a"), "dev-a"));
        assert!(!should_skip_sender_device(Some("dev-a"), "dev-b"));

        let request = push_send_request(
            PushEnvironment::Sandbox,
            PushMode::PrivacyFirst,
            Some(PushKind::Message),
            WakeupClass::Generic,
        );
        assert_eq!(request.push_kind, None);
        assert!(push_token_accepts_wakeup(
            PushTokenKind::Alert,
            WakeupClass::Generic
        ));
        assert!(!push_token_accepts_wakeup(
            PushTokenKind::Alert,
            WakeupClass::VoipOpaque
        ));

        let request = push_send_request(
            PushEnvironment::Production,
            PushMode::FastNotify,
            Some(PushKind::Call),
            WakeupClass::VoipOpaque,
        );
        assert_eq!(request.push_kind, None);
        assert_eq!(request.wakeup_class, WakeupClass::VoipOpaque);

        let request = push_send_request(
            PushEnvironment::Production,
            PushMode::FastNotify,
            Some(PushKind::Message),
            WakeupClass::Generic,
        );
        assert_eq!(request.push_kind, Some(PushKind::Message));
    }

    #[test]
    fn keeps_missing_voip_tokens_retryable() {
        assert_eq!(
            missing_push_tokens_decision(WakeupClass::Generic),
            JobDecision::MarkSent {
                outcome: Some("skipped_no_tokens")
            }
        );
        assert_eq!(
            missing_push_tokens_decision(WakeupClass::VoipOpaque),
            JobDecision::MarkFailed {
                error: "missing_voip_token".to_owned()
            }
        );
    }

    #[test]
    fn maps_outbox_and_push_completion_decisions() {
        assert_eq!(
            outbox_decision(0, false, 500, "server error"),
            JobDecision::MarkSent { outcome: None }
        );
        assert_eq!(
            outbox_decision(1, true, 200, "ok"),
            JobDecision::MarkSent { outcome: None }
        );
        assert_eq!(
            outbox_decision(1, false, 503, "unavailable"),
            JobDecision::MarkFailed {
                error: "HTTP 503: unavailable".to_owned()
            }
        );

        assert_eq!(
            push_completion_decision(true, Some("ignored")),
            JobDecision::MarkSent { outcome: None }
        );
        assert_eq!(
            push_completion_decision(false, Some("InternalServerError")),
            JobDecision::MarkFailed {
                error: "InternalServerError".to_owned()
            }
        );
        assert_eq!(
            push_completion_decision(false, None),
            JobDecision::MarkSent {
                outcome: Some("completed_without_delivery")
            }
        );
    }

    #[test]
    fn preserves_media_cleanup_metadata_when_ciphertext_delete_fails() {
        assert!(should_remove_ciphertext_for_cleanup(
            "uploaded_verified",
            Some("cipher-bucket"),
            Some("media/key-1")
        ));
        assert!(!should_remove_ciphertext_for_cleanup(
            "pending",
            Some("cipher-bucket"),
            Some("media/key-2")
        ));
        assert!(should_delete_media_metadata(false, false));
        assert!(should_delete_media_metadata(true, true));
        assert!(!should_delete_media_metadata(true, false));
    }
}
