//! Minimal Engine.IO v4 / Socket.IO packet contract used by the iOS client.
//!
//! This module intentionally supports only the packet subset required by the current `TellMe` client: direct websocket
//! transport, connect auth, event packets, ping/pong, and explicit rejection of legacy plaintext call signaling events.

use crate::sync::{ClientEvent, ServerEvent};
use serde::Serialize;
use serde_json::{json, Value};
use std::error::Error;
use std::fmt::{Display, Formatter};

const ENGINE_IO_OPEN_PACKET: char = '0';
const SOCKET_IO_CONNECT_PACKET: &str = "40";
const SOCKET_IO_EVENT_PACKET: &str = "42";
const SOCKET_IO_ERROR_PACKET: &str = "44";

/// Parsed client packet from the minimal Socket.IO subset.
#[derive(Debug, Clone, PartialEq, Eq)]
// Socket events mirror REST sync semantics so realtime delivery remains an optimization, not a second protocol.
pub enum ClientPacket {
    Connect {
        token: String,
    },
    Event {
        name: String,
        payload: Option<Value>,
    },
    Ping,
    Pong,
    Unknown,
}

/// Socket.IO packet encoding or decoding error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SocketIoError {
    MissingAuthToken,
    Json,
}

impl Display for SocketIoError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingAuthToken => formatter.write_str("missing socket auth token"),
            Self::Json => formatter.write_str("invalid socket json"),
        }
    }
}

impl Error for SocketIoError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct EngineOpenPayload<'a> {
    sid: &'a str,
    upgrades: Vec<&'static str>,
    #[serde(rename = "pingInterval")]
    ping_interval: u64,
    #[serde(rename = "pingTimeout")]
    ping_timeout: u64,
    #[serde(rename = "maxPayload")]
    max_payload: u64,
}

/// Encodes the Engine.IO open packet sent before Socket.IO auth.
///
/// # Errors
///
/// Returns `SocketIoError` only if JSON serialization fails.
pub fn encode_open_packet(socket_id: &str) -> Result<String, SocketIoError> {
    let payload = EngineOpenPayload {
        sid: socket_id,
        upgrades: Vec::new(),
        ping_interval: 25_000,
        ping_timeout: 20_000,
        max_payload: 1_000_000,
    };
    let json = serde_json::to_string(&payload).map_err(|_| SocketIoError::Json)?;

    Ok(format!("{ENGINE_IO_OPEN_PACKET}{json}"))
}

/// Encodes a Socket.IO connection acknowledgement.
#[must_use]
pub fn encode_connect_ack() -> String {
    SOCKET_IO_CONNECT_PACKET.to_owned()
}

/// Encodes a Socket.IO error packet without echoing rejected client payloads.
///
/// # Errors
///
/// Returns `SocketIoError` only if JSON serialization fails.
pub fn encode_error(message: &str) -> Result<String, SocketIoError> {
    let payload =
        serde_json::to_string(&json!({ "message": message })).map_err(|_| SocketIoError::Json)?;

    Ok(format!("{SOCKET_IO_ERROR_PACKET}{payload}"))
}

/// Encodes a Socket.IO server event packet.
///
/// # Errors
///
/// Returns `SocketIoError` only if JSON serialization fails.
pub fn encode_server_event<T: Serialize>(
    event: ServerEvent,
    payload: &T,
) -> Result<String, SocketIoError> {
    let packet = serde_json::to_string(&json!([event.as_wire(), payload]))
        .map_err(|_| SocketIoError::Json)?;

    Ok(format!("{SOCKET_IO_EVENT_PACKET}{packet}"))
}

/// Decodes a client packet from the subset emitted by the iOS `SocketIOPacketCodec`.
#[must_use]
pub fn decode_client_packet(message: &str) -> ClientPacket {
    match message {
        "2" => ClientPacket::Ping,
        "3" => ClientPacket::Pong,
        value if value.starts_with(SOCKET_IO_CONNECT_PACKET) => decode_connect(value),
        value if value.starts_with(SOCKET_IO_EVENT_PACKET) => decode_event(value),
        _ => ClientPacket::Unknown,
    }
}

/// Maps a wire event name to the accepted client event contract.
#[must_use]
pub fn client_event_from_wire(name: &str) -> Option<ClientEvent> {
    match name {
        "sync_subscribe" => Some(ClientEvent::SyncSubscribe),
        "sync_pull" => Some(ClientEvent::SyncPull),
        "presence_touch" => Some(ClientEvent::PresenceTouch),
        "join_conversation" => Some(ClientEvent::JoinConversation),
        "leave_conversation" => Some(ClientEvent::LeaveConversation),
        "presence_offline" => Some(ClientEvent::PresenceOffline),
        _ => None,
    }
}

/// Extracts `sync_pull.limit` from an event payload.
#[must_use]
pub fn sync_pull_limit_payload(payload: Option<&Value>) -> Option<i64> {
    payload
        .and_then(|value| value.get("limit"))
        .and_then(Value::as_i64)
}

/// Returns true for legacy plaintext call signaling event names that are forbidden in production.
#[must_use]
pub fn is_plaintext_call_event(name: &str) -> bool {
    matches!(
        name,
        "call_offer"
            | "call_answer"
            | "call_ice_candidate"
            | "call_media_state"
            | "call_flush_candidates"
            | "incoming_call"
            | "call_answered"
            | "call_ended"
            | "call_missed"
            | "call_quality_update"
            | "call_mute_toggled"
            | "call_camera_toggled"
            | "call_reconnecting"
    )
}

fn decode_connect(message: &str) -> ClientPacket {
    let Some(raw_payload) = message.strip_prefix(SOCKET_IO_CONNECT_PACKET) else {
        return ClientPacket::Unknown;
    };
    if raw_payload.is_empty() {
        return ClientPacket::Unknown;
    }

    let Ok(value) = serde_json::from_str::<Value>(raw_payload) else {
        return ClientPacket::Unknown;
    };
    let Some(token) = value.get("token").and_then(Value::as_str) else {
        return ClientPacket::Unknown;
    };
    if token.is_empty() {
        return ClientPacket::Unknown;
    }

    ClientPacket::Connect {
        token: token.to_owned(),
    }
}

fn decode_event(message: &str) -> ClientPacket {
    let Some(raw_payload) = message.strip_prefix(SOCKET_IO_EVENT_PACKET) else {
        return ClientPacket::Unknown;
    };
    let Ok(value) = serde_json::from_str::<Value>(raw_payload) else {
        return ClientPacket::Unknown;
    };
    let Some(array) = value.as_array() else {
        return ClientPacket::Unknown;
    };
    let Some(name) = array.first().and_then(Value::as_str) else {
        return ClientPacket::Unknown;
    };

    ClientPacket::Event {
        name: name.to_owned(),
        payload: array.get(1).cloned(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        client_event_from_wire, decode_client_packet, encode_connect_ack, encode_error,
        encode_open_packet, encode_server_event, is_plaintext_call_event, sync_pull_limit_payload,
        ClientPacket,
    };
    use crate::sync::{ClientEvent, ServerEvent};
    use crate::sync_service::SyncBlobsResponse;

    #[test]
    fn encodes_engine_open_packet_for_ios_urlsession_client() {
        let encoded = encode_open_packet("socket-1").unwrap_or_else(|_| String::new());

        assert!(encoded.starts_with('0'));
        assert!(encoded.contains("\"sid\":\"socket-1\""));
        assert!(encoded.contains("\"pingInterval\":25000"));
        assert!(encoded.contains("\"upgrades\":[]"));
    }

    #[test]
    fn decodes_connect_auth_without_query_string_tokens() {
        let packet = decode_client_packet("40{\"token\":\"session-token\"}");

        assert_eq!(
            packet,
            ClientPacket::Connect {
                token: "session-token".to_owned(),
            }
        );
        assert_eq!(decode_client_packet("40"), ClientPacket::Unknown);
        assert_eq!(
            decode_client_packet("40{\"token\":\"\"}"),
            ClientPacket::Unknown
        );
    }

    #[test]
    fn decodes_client_events_and_limits() {
        let packet = decode_client_packet("42[\"sync_pull\",{\"limit\":500}]");
        assert!(matches!(packet, ClientPacket::Event { .. }));
        let ClientPacket::Event { name, payload } = packet else {
            return;
        };

        assert_eq!(client_event_from_wire(&name), Some(ClientEvent::SyncPull));
        assert_eq!(sync_pull_limit_payload(payload.as_ref()), Some(500));
    }

    #[test]
    fn encodes_server_events_like_ios_codec_expects() {
        let response = SyncBlobsResponse {
            device_id: "ios-primary".to_owned(),
            blobs: Vec::new(),
        };
        let encoded = encode_server_event(ServerEvent::SyncBlobs, &response)
            .unwrap_or_else(|_| String::new());

        assert!(encoded.starts_with("42[\"sync_blobs\""));
        assert!(encoded.contains("\"device_id\":\"ios-primary\""));
        assert_eq!(encode_connect_ack(), "40");
    }

    #[test]
    fn rejects_plaintext_call_signaling_events_without_echoing_payload() {
        assert!(is_plaintext_call_event("call_offer"));
        assert!(is_plaintext_call_event("call_ice_candidate"));
        assert!(is_plaintext_call_event("call_media_state"));
        assert!(!is_plaintext_call_event("sync_pull"));

        let encoded = encode_error("Call signaling moved to E2E message types")
            .unwrap_or_else(|_| String::new());
        assert!(encoded.starts_with("44"));
        assert!(encoded.contains("Call signaling moved to E2E message types"));
        assert!(!encoded.contains("sdp"));
        assert!(!encoded.contains("candidate"));
    }
}
