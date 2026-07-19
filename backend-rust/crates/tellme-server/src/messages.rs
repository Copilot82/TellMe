//! Message routing-envelope contract.
//!
//! Message payloads remain opaque ciphertext. This module only handles the routing metadata the server
//! is allowed to see.

use crate::auth::{normalize_handle, parse_handle};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::error::Error;
use std::fmt::{Display, Formatter};

/// Current wire version for delivery units.
pub const WIRE_VERSION_V2: u8 = 2;

/// Minimum mailbox TTL accepted by the current API.
pub const DELIVERY_TTL_MIN_SEC: u64 = 60;

/// Maximum mailbox TTL accepted by the current API.
pub const DELIVERY_TTL_MAX_SEC: u64 = 60 * 60 * 24 * 30;

/// Maximum deliveries accepted in one send request.
pub const MAX_DELIVERIES_PER_SEND: usize = 500;

/// Maximum message IDs accepted in one ack request.
pub const MAX_ACK_IDS: usize = 1_000;

/// Optional push classification from the encrypted-message envelope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushKind {
    Message,
    Call,
    CallMissed,
    Other,
}

impl PushKind {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Message => "message",
            Self::Call => "call",
            Self::CallMissed => "call_missed",
            Self::Other => "other",
        }
    }
}

/// Privacy-safe wake routing class. This is the only call wake hint the backend may see.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WakeupClass {
    Generic,
    VoipOpaque,
}

impl WakeupClass {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Generic => "generic",
            Self::VoipOpaque => "voip_opaque",
        }
    }
}

/// One delivery unit from `/messages/send`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeliveryUnit {
    pub wire_version: u8,
    pub delivery_id: String,
    pub to_server: String,
    pub to_user: String,
    pub to_device_id: String,
    pub message_id: String,
    pub timestamp: String,
    pub ttl_sec: u64,
    pub ciphertext_blob: String,
    pub push_kind: Option<PushKind>,
    #[serde(default)]
    pub wakeup_class: Option<WakeupClass>,
}

/// Delivery routing result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeliveryRouting {
    pub is_local: bool,
    pub target_server: String,
}

/// Input for delivery routing resolution.
#[derive(Debug, Clone, Copy)]
pub struct DeliveryRoutingInput<'a> {
    pub to_server: &'a str,
    pub to_user: &'a str,
    pub server_domain: Option<&'a str>,
    pub sender_handle: Option<&'a str>,
    pub aliases_raw: Option<&'a str>,
}

/// Message contract error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MessageError {
    EmptyDeliveryBatch,
    DeliveryBatchTooLarge,
    InvalidWireVersion,
    InvalidUuid,
    InvalidRoutingField,
    InvalidTtl,
    EmptyCiphertext,
    AckBatchTooLarge,
}

impl Display for MessageError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EmptyDeliveryBatch => formatter.write_str("delivery batch is empty"),
            Self::DeliveryBatchTooLarge => formatter.write_str("delivery batch is too large"),
            Self::InvalidWireVersion => formatter.write_str("invalid message wire version"),
            Self::InvalidUuid => formatter.write_str("invalid message UUID"),
            Self::InvalidRoutingField => formatter.write_str("invalid message routing field"),
            Self::InvalidTtl => formatter.write_str("invalid delivery ttl"),
            Self::EmptyCiphertext => formatter.write_str("ciphertext blob is empty"),
            Self::AckBatchTooLarge => formatter.write_str("ack batch is too large"),
        }
    }
}

impl Error for MessageError {}

/// Validates one delivery unit without inspecting ciphertext contents.
///
/// # Errors
///
/// Returns an error when visible routing metadata violates the current API bounds.
pub fn validate_delivery(delivery: &DeliveryUnit) -> Result<(), MessageError> {
    if delivery.wire_version != WIRE_VERSION_V2 {
        return Err(MessageError::InvalidWireVersion);
    }

    if !is_uuid_like(&delivery.delivery_id) || !is_uuid_like(&delivery.message_id) {
        return Err(MessageError::InvalidUuid);
    }

    if delivery.to_server.is_empty()
        || delivery.to_server.len() > 255
        || delivery.to_user.len() < 3
        || delivery.to_user.len() > 255
        || delivery.to_device_id.is_empty()
        || delivery.to_device_id.len() > 255
    {
        return Err(MessageError::InvalidRoutingField);
    }

    if delivery.ttl_sec < DELIVERY_TTL_MIN_SEC || delivery.ttl_sec > DELIVERY_TTL_MAX_SEC {
        return Err(MessageError::InvalidTtl);
    }

    if delivery.ciphertext_blob.is_empty() {
        return Err(MessageError::EmptyCiphertext);
    }

    Ok(())
}

/// Validates the `/messages/send` batch bounds and every delivery envelope.
///
/// # Errors
///
/// Returns an error when the batch is empty, too large, or contains an invalid delivery.
pub fn validate_send_batch(deliveries: &[DeliveryUnit]) -> Result<(), MessageError> {
    if deliveries.is_empty() {
        return Err(MessageError::EmptyDeliveryBatch);
    }

    if deliveries.len() > MAX_DELIVERIES_PER_SEND {
        return Err(MessageError::DeliveryBatchTooLarge);
    }

    for delivery in deliveries {
        validate_delivery(delivery)?;
    }

    Ok(())
}

/// Validates `/messages/ack` message ID bounds.
///
/// # Errors
///
/// Returns an error when the ack batch is too large or contains an invalid UUID.
pub fn validate_ack_ids(message_ids: &[String]) -> Result<(), MessageError> {
    if message_ids.len() > MAX_ACK_IDS {
        return Err(MessageError::AckBatchTooLarge);
    }

    if message_ids
        .iter()
        .any(|message_id| !is_uuid_like(message_id))
    {
        return Err(MessageError::InvalidUuid);
    }

    Ok(())
}

#[must_use]
pub fn normalized_delivery(delivery: &DeliveryUnit) -> DeliveryUnit {
    let mut normalized = delivery.clone();
    normalized.to_user = normalize_handle(&delivery.to_user);
    normalized
}

#[must_use]
pub fn resolve_delivery_routing(input: &DeliveryRoutingInput<'_>) -> DeliveryRouting {
    let explicit_to_server = normalize_domain(Some(input.to_server)).unwrap_or_default();
    let handle_domain = domain_from_handle(Some(input.to_user)).unwrap_or_default();
    let local_domains =
        collect_local_domains(input.server_domain, input.sender_handle, input.aliases_raw);
    let target_server = if handle_domain.is_empty() {
        explicit_to_server.clone()
    } else {
        handle_domain
    };
    let is_local = local_domains.contains(&target_server)
        || (!explicit_to_server.is_empty() && local_domains.contains(&explicit_to_server));

    DeliveryRouting {
        is_local,
        target_server: if target_server.is_empty() {
            explicit_to_server
        } else {
            target_server
        },
    }
}

#[must_use]
pub fn sender_server_from_handle(sender_handle: &str) -> String {
    sender_handle
        .split_once(':')
        .map_or_else(|| "unknown".to_owned(), |(_, domain)| domain.to_owned())
}

#[must_use]
pub const fn push_kind_for_job(
    allowed_fast_notify: bool,
    push_kind: Option<PushKind>,
) -> Option<PushKind> {
    if !allowed_fast_notify {
        return None;
    }

    match push_kind {
        Some(PushKind::Call | PushKind::CallMissed) => None,
        other => other,
    }
}

#[must_use]
pub const fn local_result_status(
    local_account_exists: bool,
    target_device_count: usize,
) -> &'static str {
    if local_account_exists && target_device_count > 0 {
        "queued_local"
    } else {
        "unavailable"
    }
}

fn normalize_domain(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim().to_ascii_lowercase();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn aliases_from_raw(raw: Option<&str>) -> Vec<String> {
    raw.map(|inner| {
        inner
            .split(',')
            .filter_map(|item| normalize_domain(Some(item)))
            .collect()
    })
    .unwrap_or_default()
}

fn domain_from_handle(handle: Option<&str>) -> Option<String> {
    let normalized = normalize_handle(handle.unwrap_or_default());
    parse_handle(&normalized)
        .ok()
        .map(|parsed| parsed.domain().to_owned())
}

fn collect_local_domains(
    server_domain: Option<&str>,
    sender_handle: Option<&str>,
    aliases_raw: Option<&str>,
) -> BTreeSet<String> {
    let mut domains = BTreeSet::new();

    if let Some(domain) = normalize_domain(server_domain) {
        domains.insert(domain);
    }
    if let Some(domain) = domain_from_handle(sender_handle) {
        domains.insert(domain);
    }
    for alias in aliases_from_raw(aliases_raw) {
        domains.insert(alias);
    }

    domains
}

#[must_use]
pub fn is_uuid_like(value: &str) -> bool {
    let mut sections = value.split('-');
    let valid = matches!(sections.next().map(str::len), Some(8))
        && matches!(sections.next().map(str::len), Some(4))
        && matches!(sections.next().map(str::len), Some(4))
        && matches!(sections.next().map(str::len), Some(4))
        && matches!(sections.next().map(str::len), Some(12))
        && sections.next().is_none();

    valid
        && value
            .chars()
            .all(|item| item.is_ascii_hexdigit() || item == '-')
}

#[cfg(test)]
mod tests {
    use super::{
        local_result_status, normalized_delivery, push_kind_for_job, resolve_delivery_routing,
        sender_server_from_handle, validate_ack_ids, validate_delivery, validate_send_batch,
        DeliveryRoutingInput, DeliveryUnit, MessageError, PushKind, WakeupClass,
    };

    #[test]
    fn validates_delivery_envelope_without_reading_ciphertext() {
        assert_eq!(validate_delivery(&delivery()), Ok(()));

        let mut invalid = delivery();
        invalid.ttl_sec = 59;
        assert_eq!(validate_delivery(&invalid), Err(MessageError::InvalidTtl));

        let mut invalid = delivery();
        invalid.ciphertext_blob = String::new();
        assert_eq!(
            validate_delivery(&invalid),
            Err(MessageError::EmptyCiphertext)
        );
    }

    #[test]
    fn validates_send_and_ack_batch_bounds() {
        assert_eq!(validate_send_batch(&[delivery()]), Ok(()));
        assert_eq!(
            validate_send_batch(&[]),
            Err(MessageError::EmptyDeliveryBatch)
        );

        let ids = vec!["55555555-5555-4555-8555-555555555555".to_owned()];
        assert_eq!(validate_ack_ids(&ids), Ok(()));
        let invalid_ids = vec!["not-a-uuid".to_owned()];
        assert_eq!(
            validate_ack_ids(&invalid_ids),
            Err(MessageError::InvalidUuid)
        );
    }

    #[test]
    fn normalizes_delivery_user_handle() {
        let mut raw = delivery();
        raw.to_user = " @Bob:VPN.Internal ".to_owned();

        assert_eq!(normalized_delivery(&raw).to_user, "@bob:vpn.internal");
    }

    #[test]
    fn resolves_local_delivery_from_server_aliases_and_sender_domain() {
        let routing = resolve_delivery_routing(&DeliveryRoutingInput {
            to_server: "internal-vpn.local",
            to_user: "@bob:messenger.example.com",
            server_domain: Some("messenger.example.com"),
            sender_handle: Some("@alice:messenger.example.com"),
            aliases_raw: Some("internal-vpn.local,messenger.example.com"),
        });

        assert!(routing.is_local);
        assert_eq!(routing.target_server, "messenger.example.com");
    }

    #[test]
    fn resolves_remote_delivery_to_handle_domain() {
        let routing = resolve_delivery_routing(&DeliveryRoutingInput {
            to_server: "domain-b.example",
            to_user: "@bob:domain-b.example",
            server_domain: Some("domain-a.example"),
            sender_handle: Some("@alice:domain-a.example"),
            aliases_raw: Some("vpn-a.internal"),
        });

        assert!(!routing.is_local);
        assert_eq!(routing.target_server, "domain-b.example");
    }

    #[test]
    fn preserves_privacy_for_plaintext_call_push_kind() {
        assert_eq!(push_kind_for_job(false, Some(PushKind::Message)), None);
        assert_eq!(
            push_kind_for_job(true, Some(PushKind::Message)),
            Some(PushKind::Message)
        );
        assert_eq!(push_kind_for_job(true, Some(PushKind::Call)), None);
        assert_eq!(push_kind_for_job(true, Some(PushKind::CallMissed)), None);
        assert_eq!(WakeupClass::VoipOpaque.as_wire(), "voip_opaque");
    }

    #[test]
    fn maps_sender_server_and_local_status() {
        assert_eq!(
            sender_server_from_handle("@alice:messenger.example.com"),
            "messenger.example.com"
        );
        assert_eq!(sender_server_from_handle("invalid"), "unknown");
        assert_eq!(local_result_status(true, 1), "queued_local");
        assert_eq!(local_result_status(true, 0), "unavailable");
        assert_eq!(local_result_status(false, 1), "unavailable");
    }

    fn delivery() -> DeliveryUnit {
        DeliveryUnit {
            wire_version: 2,
            delivery_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            to_server: "public.example.com".to_owned(),
            to_user: "@bob:vpn.internal".to_owned(),
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
