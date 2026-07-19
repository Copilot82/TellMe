#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use std::convert::TryFrom;
use std::env;
use std::error::Error;
use std::fmt::{Display, Formatter};
use std::io::{ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::ws::{Message as WebSocketMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, Json, Path, Query, State};
use axum::http::{HeaderMap, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response as AxumResponse};
use axum::routing::{any, get};
use axum::Router;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

use crate::auth_repository::PostgresAuthRepository;
use crate::auth_service::{
    AuthFinishRequest, AuthStartRequest, AuthenticatedSession, LogoutRequest, RefreshRequest,
    RegisterRequest,
};
use crate::contract::ROUTES;
use crate::device_link_repository::PostgresDeviceLinkRepository;
use crate::device_link_service::{
    LinkApproveRequest, LinkCompleteRequest, LinkRequestCreateRequest, LinkStartRequest,
};
use crate::device_repository::PostgresDeviceRepository;
use crate::device_service::{
    DeviceRegisterRequest, DeviceRevokeRequest, DeviceRouteRecord, PushTokenRecord,
    PushTokenUpdate, PushTokenUpsert,
};
use crate::federation::FederationHeaders;
use crate::federation_repository::PostgresFederationRepository;
use crate::federation_service::{
    FederationAuthRequest, FederationDeliverRequest, FederationPrekeyRequest,
    FederationReceiptsRequest,
};
use crate::media::{
    bearer_capability_token, canonicalize_risk_flags, ciphertext_response_headers,
    hash_capability_token, parse_media_scan_verdict, validate_media_upload, MediaError,
    MediaRejectReason, MediaUploadAttestation, MediaUploadValidationInput,
};
use crate::media_repository::PostgresMediaRepository;
use crate::media_service::{
    media_rejection_error, MarkUploadedVerified, MediaObjectRecord, MediaStatus,
    MediaUploadInitRequest, MediaUploadPolicy, MediaUploadResponse,
};
use crate::media_storage::MinioMediaObjectStore;
use crate::message_repository::PostgresMessageRepository;
use crate::message_service::{MessageAckRequest, MessageSendContext, MessageSendRequest};
use crate::prekey_repository::PostgresPrekeyRepository;
use crate::prekey_service::{PrekeyLookupRequest, SelfPrekeyRequest};
use crate::prekeys::{parse_peek_query, PrekeyPublishRequest};
use crate::rate_limit::{
    bypass_for_session_claims, normalize_key, record_window_hit, too_many_requests_error,
    CounterState, RateLimitDecision, AUTH_RATE_LIMIT_PER_MINUTE,
    FEDERATION_PREAUTH_RATE_LIMIT_PER_MINUTE, FEDERATION_RATE_LIMIT_PER_MINUTE,
    PUBLIC_DIRECTORY_RATE_LIMIT_PER_MINUTE,
};
use crate::realtime::{RealtimeEnvelope, RealtimeHub, RealtimePayload};
use crate::redis_sync_repository::{RedisSyncConfig, RedisSyncRepository};
use crate::session::{TokenConfig, TokenKind};
use crate::session_repository::PostgresSessionRepository;
use crate::socket_io::{
    client_event_from_wire, decode_client_packet, encode_connect_ack, encode_error,
    encode_open_packet, encode_server_event, is_plaintext_call_event, sync_pull_limit_payload,
    ClientPacket,
};
use crate::sync::{socket_pull_limit, ClientEvent, ServerEvent};
use crate::sync_repository::PostgresSyncRepository;
use crate::sync_service::SocketPresenceContext;
use crate::sync_service::SyncStreamRequest;
use crate::turn::TurnCredentialsRequest;

// Public modules are exported intentionally so route adapters can compose the service contracts directly.
pub mod auth;
pub mod auth_repository;
pub mod auth_service;
pub mod contract;
pub mod database;
pub mod device_link_repository;
pub mod device_link_service;
pub mod device_repository;
pub mod device_service;
pub mod devices;
pub mod federation;
pub mod federation_repository;
pub mod federation_service;
pub mod federation_transport;
pub mod hashing;
pub mod media;
pub mod media_repository;
pub mod media_service;
pub mod media_storage;
pub mod message_repository;
pub mod message_service;
pub mod messages;
pub mod migrations;
pub mod prekey_repository;
pub mod prekey_service;
pub mod prekeys;
pub mod push_provider;
pub mod rate_limit;
pub mod realtime;
pub mod redis_sync_repository;
pub mod session;
pub mod session_repository;
pub mod socket_io;
pub mod sync;
pub mod sync_repository;
pub mod sync_service;
pub mod turn;
pub mod worker_repository;
pub mod worker_runtime;
pub mod worker_scheduler;
pub mod worker_service;
pub mod workers;

const DEFAULT_BIND_ADDR: &str = "127.0.0.1:3101";
const DEFAULT_SERVER_DOMAIN: &str = "localhost";
const DEFAULT_MAX_UPLOAD_BYTES: u64 = 10_485_760;
const DEFAULT_SHUTDOWN_TIMEOUT_MS: u64 = 5_000;

/// Runtime configuration that is safe to expose through the public config route.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    bind_addr: SocketAddr,
    server_domain: String,
    max_upload_bytes: u64,
    shutdown_timeout: Duration,
}

impl Config {
    /// Builds configuration from environment variables.
    ///
    /// # Errors
    ///
    /// Returns an error when a configured socket address, server domain, or numeric value is invalid.
    pub fn from_env() -> Result<Self, ConfigError> {
        let bind_raw =
            env::var("TELLME_RUST_BIND_ADDR").unwrap_or_else(|_| DEFAULT_BIND_ADDR.to_owned());
        let bind_addr = bind_raw
            .parse::<SocketAddr>()
            .map_err(|_| ConfigError::BindAddress(bind_raw))?;

        let server_domain =
            env::var("SERVER_DOMAIN").unwrap_or_else(|_| DEFAULT_SERVER_DOMAIN.to_owned());
        if !is_valid_domain(&server_domain) {
            return Err(ConfigError::ServerDomain(server_domain));
        }

        let max_upload_bytes = read_u64_env("MAX_FILE_SIZE", DEFAULT_MAX_UPLOAD_BYTES)?;
        let shutdown_timeout_ms = read_u64_env(
            "TELLME_RUST_SHUTDOWN_TIMEOUT_MS",
            DEFAULT_SHUTDOWN_TIMEOUT_MS,
        )?;

        Ok(Self::new(
            bind_addr,
            server_domain,
            max_upload_bytes,
            Duration::from_millis(shutdown_timeout_ms),
        ))
    }

    #[must_use]
    pub const fn new(
        bind_addr: SocketAddr,
        server_domain: String,
        max_upload_bytes: u64,
        shutdown_timeout: Duration,
    ) -> Self {
        Self {
            bind_addr,
            server_domain,
            max_upload_bytes,
            shutdown_timeout,
        }
    }

    #[must_use]
    pub const fn bind_addr(&self) -> SocketAddr {
        self.bind_addr
    }

    #[must_use]
    pub fn server_domain(&self) -> &str {
        &self.server_domain
    }

    #[must_use]
    pub const fn max_upload_bytes(&self) -> u64 {
        self.max_upload_bytes
    }

    #[must_use]
    pub const fn shutdown_timeout(&self) -> Duration {
        self.shutdown_timeout
    }
}

/// Configuration loading error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    BindAddress(String),
    ServerDomain(String),
    Number { name: String, value: String },
}

impl Display for ConfigError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BindAddress(value) => write!(formatter, "invalid bind address: {value}"),
            Self::ServerDomain(value) => write!(formatter, "invalid server domain: {value}"),
            Self::Number { name, value } => {
                write!(formatter, "invalid numeric env {name}: {value}")
            }
        }
    }
}

impl Error for ConfigError {}

/// Server runtime error.
#[derive(Debug)]
pub enum ServerError {
    Io(std::io::Error),
}

impl Display for ServerError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "server io error: {error}"),
        }
    }
}

impl Error for ServerError {}

impl From<std::io::Error> for ServerError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

/// Cooperative shutdown handle used by the server loop and embedding tests.
#[derive(Debug, Clone)]
pub struct ShutdownHandle {
    requested: Arc<AtomicBool>,
}

impl ShutdownHandle {
    #[must_use]
    pub fn new() -> Self {
        Self {
            requested: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn request(&self) {
        self.requested.store(true, Ordering::SeqCst);
    }

    #[must_use]
    pub fn is_requested(&self) -> bool {
        self.requested.load(Ordering::SeqCst)
    }
}

impl Default for ShutdownHandle {
    fn default() -> Self {
        Self::new()
    }
}

/// Pure request handler for the initial Rust server domain.
#[derive(Debug, Clone)]
pub struct Application {
    config: Config,
}

#[derive(Debug, Clone)]
struct HttpState {
    app: Application,
    auth: Option<PostgresAuthRepository>,
    device_links: Option<PostgresDeviceLinkRepository>,
    devices: Option<PostgresDeviceRepository>,
    federation: Option<PostgresFederationRepository>,
    messages: Option<PostgresMessageRepository>,
    media: Option<PostgresMediaRepository>,
    media_storage: Option<MinioMediaObjectStore>,
    prekeys: Option<PostgresPrekeyRepository>,
    sessions: Option<PostgresSessionRepository>,
    sync: Option<PostgresSyncRepository>,
    pool: Option<PgPool>,
    redis_sync_config: RedisSyncConfig,
    realtime: RealtimeHub,
    auth_limits: Arc<Mutex<BTreeMap<String, CounterState>>>,
    federation_domain_limits: Arc<Mutex<BTreeMap<String, CounterState>>>,
    federation_preauth_limits: Arc<Mutex<BTreeMap<String, CounterState>>>,
    public_directory_limits: Arc<Mutex<BTreeMap<String, CounterState>>>,
    turn_limits: Arc<Mutex<BTreeMap<String, CounterState>>>,
}

impl HttpState {
    #[must_use]
    fn without_persistence(config: Config) -> Self {
        Self {
            app: Application::new(config),
            auth: None,
            device_links: None,
            devices: None,
            federation: None,
            messages: None,
            media: None,
            media_storage: None,
            prekeys: None,
            sessions: None,
            sync: None,
            pool: None,
            redis_sync_config: RedisSyncConfig::from_env(),
            realtime: RealtimeHub::new(),
            auth_limits: Arc::new(Mutex::new(BTreeMap::new())),
            federation_domain_limits: Arc::new(Mutex::new(BTreeMap::new())),
            federation_preauth_limits: Arc::new(Mutex::new(BTreeMap::new())),
            public_directory_limits: Arc::new(Mutex::new(BTreeMap::new())),
            turn_limits: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    #[must_use]
    fn with_pool(config: Config, pool: PgPool, token_config: TokenConfig) -> Self {
        let realtime = RealtimeHub::new();
        Self {
            app: Application::new(config),
            auth: Some(PostgresAuthRepository::new(
                pool.clone(),
                token_config.clone(),
            )),
            device_links: Some(PostgresDeviceLinkRepository::with_realtime(
                pool.clone(),
                token_config.clone(),
                realtime.clone(),
            )),
            devices: Some(PostgresDeviceRepository::new(pool.clone())),
            federation: Some(PostgresFederationRepository::with_realtime(
                pool.clone(),
                realtime.clone(),
            )),
            messages: Some(PostgresMessageRepository::with_realtime(
                pool.clone(),
                realtime.clone(),
            )),
            media: Some(PostgresMediaRepository::new(pool.clone())),
            media_storage: MinioMediaObjectStore::from_env_optional(),
            prekeys: Some(PostgresPrekeyRepository::new(pool.clone())),
            sessions: Some(PostgresSessionRepository::new(pool.clone(), token_config)),
            sync: Some(PostgresSyncRepository::new(pool.clone())),
            pool: Some(pool),
            redis_sync_config: RedisSyncConfig::from_env(),
            realtime,
            auth_limits: Arc::new(Mutex::new(BTreeMap::new())),
            federation_domain_limits: Arc::new(Mutex::new(BTreeMap::new())),
            federation_preauth_limits: Arc::new(Mutex::new(BTreeMap::new())),
            public_directory_limits: Arc::new(Mutex::new(BTreeMap::new())),
            turn_limits: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    fn record_auth_hit(&self, raw_key: Option<&str>, now_ms: u64) -> bool {
        record_limited_hit(
            &self.auth_limits,
            raw_key,
            now_ms,
            auth_rate_limit_per_minute(),
        )
    }

    fn record_public_directory_hit(&self, raw_key: Option<&str>, now_ms: u64) -> bool {
        record_limited_hit(
            &self.public_directory_limits,
            raw_key,
            now_ms,
            public_directory_rate_limit_per_minute(),
        )
    }

    fn record_turn_hit(&self, raw_key: Option<&str>, now_ms: u64) -> bool {
        record_limited_hit(
            &self.turn_limits,
            raw_key,
            now_ms,
            turn_credentials_rate_limit_per_minute(),
        )
    }

    fn record_federation_preauth_hit(&self, raw_key: Option<&str>, now_ms: u64) -> bool {
        record_limited_hit(
            &self.federation_preauth_limits,
            raw_key,
            now_ms,
            federation_preauth_rate_limit_per_minute(),
        )
    }

    fn record_federation_domain_hit(&self, raw_key: Option<&str>, now_ms: u64) -> bool {
        record_limited_hit(
            &self.federation_domain_limits,
            raw_key,
            now_ms,
            federation_rate_limit_per_minute(),
        )
    }
}

/// Stable health response returned by `/health` and `/ready`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct HealthResponse {
    status: &'static str,
    service: &'static str,
    version: &'static str,
}

impl HealthResponse {
    #[must_use]
    pub const fn current() -> Self {
        Self {
            status: "ok",
            service: "tellme-rust",
            version: env!("CARGO_PKG_VERSION"),
        }
    }
}

/// Public configuration response safe for unauthenticated iOS bootstrap.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PublicConfigResponse {
    server_domain: String,
    wire_version: u8,
    protocol_version: u8,
    max_upload_bytes: u64,
    call_signaling: &'static str,
    media_transport: &'static str,
    direct_webrtc: &'static str,
}

impl PublicConfigResponse {
    #[must_use]
    pub fn from_config(config: &Config) -> Self {
        Self {
            server_domain: config.server_domain().to_owned(),
            wire_version: 2,
            protocol_version: 2,
            max_upload_bytes: config.max_upload_bytes(),
            call_signaling: "e2e_message_payload",
            media_transport: "webrtc_turn_relay",
            direct_webrtc: "disabled_release_1",
        }
    }
}

/// JSON API error payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ErrorResponse {
    error: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
struct DeviceResponse<'a> {
    device: &'a DeviceRouteRecord,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
struct PushTokenResponse<'a> {
    token: &'a PushTokenRecord,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct PrekeyLookupQuery {
    user: Option<String>,
    device_id: Option<String>,
    peek: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct SelfPrekeyQuery {
    device_id: Option<String>,
    peek: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct LinkPollQuery {
    poll_token: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct SyncStreamQuery {
    limit: Option<u64>,
    device_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct FederationPrekeyQuery {
    device_id: Option<String>,
    peek: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct SocketIoQuery {
    #[serde(rename = "EIO")]
    eio: Option<String>,
    transport: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SocketLoopControl {
    Continue,
    Close,
}

impl SelfPrekeyQuery {
    #[must_use]
    fn into_service_request(self) -> SelfPrekeyRequest {
        SelfPrekeyRequest {
            device_id: self.device_id,
            peek: parse_peek_query(self.peek.as_deref()),
        }
    }
}

impl SyncStreamQuery {
    #[must_use]
    fn into_service_request(self) -> SyncStreamRequest {
        SyncStreamRequest {
            limit: self.limit,
            device_id: self.device_id,
        }
    }
}

impl PrekeyLookupQuery {
    #[must_use]
    fn into_service_request(self) -> PrekeyLookupRequest {
        PrekeyLookupRequest {
            user: self.user,
            device_id: self.device_id,
            peek: parse_peek_query(self.peek.as_deref()),
        }
    }
}

impl FederationPrekeyQuery {
    #[must_use]
    fn into_service_request(self, user_handle: String) -> FederationPrekeyRequest {
        FederationPrekeyRequest {
            user_handle,
            device_id: self.device_id,
            peek: parse_peek_query(self.peek.as_deref()),
        }
    }
}

impl Application {
    #[must_use]
    pub const fn new(config: Config) -> Self {
        Self { config }
    }

    #[must_use]
    pub fn handle(&self, request: &Request) -> Response {
        let path = path_without_query(request.path());
        match (request.method(), path) {
            ("GET", "/health" | "/ready") => Self::health_response(),
            ("GET", "/api/config" | "/config") => self.config_response(),
            (method, path) if matches_contract_route(method, path) => json_response(
                Status::NotImplemented,
                &ErrorResponse {
                    error: "Rust route awaits persistence adapter",
                },
            ),
            (method, path)
                if matches_contract_path(path) && !matches_contract_route(method, path) =>
            {
                json_response(
                    Status::MethodNotAllowed,
                    &ErrorResponse {
                        error: "Method not allowed",
                    },
                )
            }
            ("GET", _) => json_response(Status::NotFound, &ErrorResponse { error: "Not found" }),
            _ => json_response(
                Status::MethodNotAllowed,
                &ErrorResponse {
                    error: "Method not allowed",
                },
            ),
        }
    }

    #[must_use]
    fn health_response() -> Response {
        json_response(Status::Ok, &HealthResponse::current())
    }

    #[must_use]
    fn config_response(&self) -> Response {
        json_response(Status::Ok, &PublicConfigResponse::from_config(&self.config))
    }
}

/// Minimal parsed `HTTP` request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    method: String,
    path: String,
}

impl Request {
    #[must_use]
    pub fn new(method: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            method: method.into(),
            path: path.into(),
        }
    }

    #[must_use]
    pub fn get(path: impl Into<String>) -> Self {
        Self::new("GET", path)
    }

    #[must_use]
    pub fn method(&self) -> &str {
        &self.method
    }

    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }
}

/// Minimal `HTTP` response with stable JSON error shapes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    status: Status,
    content_type: &'static str,
    body: String,
}

impl Response {
    #[must_use]
    pub const fn json(status: Status, body: String) -> Self {
        Self {
            status,
            content_type: "application/json",
            body,
        }
    }

    #[must_use]
    pub const fn status(&self) -> Status {
        self.status
    }

    #[must_use]
    pub fn body(&self) -> &str {
        &self.body
    }

    #[must_use]
    pub fn to_http_bytes(&self) -> Vec<u8> {
        format!(
            "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nCache-Control: no-store\r\nContent-Length: {}\r\n\r\n{}",
            self.status.code(),
            self.status.reason(),
            self.content_type,
            self.body.len(),
            self.body
        )
        .into_bytes()
    }

    #[must_use]
    pub fn into_axum_response(self) -> AxumResponse {
        let status = StatusCode::from_u16(self.status.code())
            .map_or(StatusCode::INTERNAL_SERVER_ERROR, |status| status);
        (
            status,
            [
                ("content-type", self.content_type),
                ("cache-control", "no-store"),
            ],
            self.body,
        )
            .into_response()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    NotFound,
    NotImplemented,
    MethodNotAllowed,
    InternalServerError,
}

impl Status {
    #[must_use]
    pub const fn code(self) -> u16 {
        match self {
            Self::Ok => 200,
            Self::NotFound => 404,
            Self::NotImplemented => 501,
            Self::MethodNotAllowed => 405,
            Self::InternalServerError => 500,
        }
    }

    #[must_use]
    pub const fn reason(self) -> &'static str {
        match self {
            Self::Ok => "OK",
            Self::NotFound => "Not Found",
            Self::NotImplemented => "Not Implemented",
            Self::MethodNotAllowed => "Method Not Allowed",
            Self::InternalServerError => "Internal Server Error",
        }
    }
}

/// Runs the blocking `HTTP` server until the shutdown handle is requested.
///
/// # Errors
///
/// Returns an error when listener configuration, accepting a connection, reading a request, or writing a response fails.
pub fn serve(
    listener: &TcpListener,
    app: &Application,
    shutdown: &ShutdownHandle,
) -> Result<(), ServerError> {
    listener.set_nonblocking(true)?;

    while !shutdown.is_requested() {
        match listener.accept() {
            Ok((mut stream, _peer)) => {
                handle_stream(&mut stream, app)?;
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(25));
            }
            Err(error) => return Err(ServerError::Io(error)),
        }
    }

    thread::sleep(app.config.shutdown_timeout());
    Ok(())
}

/// Builds the production `axum` router over the pure contract-preserving application handler.
pub fn http_router(config: Config) -> Router {
    http_router_for_state(HttpState::without_persistence(config))
}

/// Builds the production `axum` router with persistence-backed route adapters.
pub fn http_router_with_pool(config: Config, pool: PgPool, token_config: TokenConfig) -> Router {
    http_router_for_state(HttpState::with_pool(config, pool, token_config))
}

fn http_router_for_state(state: HttpState) -> Router {
    Router::new()
        .route("/health", get(axum_health))
        .route("/ready", get(axum_health))
        .route("/api/config", get(axum_config))
        .route("/config", get(axum_config))
        .route("/api/auth/register", any(axum_auth_register))
        .route("/api/auth/start", any(axum_auth_start))
        .route("/api/auth/finish", any(axum_auth_finish))
        .route("/api/auth/refresh", any(axum_auth_refresh))
        .route("/api/auth/logout", any(axum_auth_logout))
        .route("/api/messages/send", any(axum_message_send))
        .route("/api/messages/ack", any(axum_message_ack))
        .route("/api/turn/credentials", any(axum_turn_credentials))
        .route("/api/sync/stream", any(axum_sync_stream))
        .route("/api/media/upload/init", any(axum_media_upload_init))
        .route("/api/media/upload/{media_id}", any(axum_media_upload))
        .route("/api/media/ciphertext/{media_id}", any(axum_media_download))
        .route("/api/devices/register", any(axum_device_register))
        .route("/api/devices/revoke", any(axum_device_revoke))
        .route("/api/devices/link/start", any(axum_device_link_start))
        .route("/api/devices/link/request", any(axum_device_link_request))
        .route(
            "/api/devices/link/session/{session_id}/requests",
            any(axum_device_link_session_requests),
        )
        .route(
            "/api/devices/link/request/{request_id}",
            any(axum_device_link_request_item),
        )
        .route("/api/devices/link/approve", any(axum_device_link_approve))
        .route("/api/devices/link/complete", any(axum_device_link_complete))
        .route("/api/devices/push/tokens", any(axum_push_tokens))
        .route(
            "/api/devices/push/tokens/{token}",
            any(axum_push_token_item),
        )
        .route("/api/prekeys/publish", any(axum_prekey_publish))
        .route("/api/prekeys/get", any(axum_prekey_lookup))
        .route("/api/prekeys/self", any(axum_prekey_self))
        .route(
            "/federation/v1/server-keys",
            any(axum_federation_server_keys),
        )
        .route(
            "/federation/v1/prekeys/{user_handle}",
            any(axum_federation_prekeys),
        )
        .route("/federation/v1/deliver", any(axum_federation_deliver))
        .route("/federation/v1/receipts", any(axum_federation_receipts))
        .route("/socket.io", get(axum_socket_io))
        .route("/socket.io/", get(axum_socket_io))
        .fallback(axum_dispatch)
        .with_state(state)
}

async fn axum_socket_io(
    State(state): State<HttpState>,
    Query(query): Query<SocketIoQuery>,
    websocket: WebSocketUpgrade,
) -> AxumResponse {
    if query.eio.as_deref() != Some("4") || query.transport.as_deref() != Some("websocket") {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid WebSocket transport",
            },
        );
    }

    websocket
        .on_upgrade(move |socket| socket_io_connection(socket, state))
        .into_response()
}

async fn socket_io_connection(mut socket: WebSocket, state: HttpState) {
    let Ok(socket_id) = socket_id() else {
        let _send_result = send_socket_error(&mut socket, "Internal server error").await;
        return;
    };
    let Ok(open_packet) = encode_open_packet(&socket_id) else {
        let _send_result = send_socket_error(&mut socket, "Internal server error").await;
        return;
    };
    if socket
        .send(WebSocketMessage::Text(open_packet.into()))
        .await
        .is_err()
    {
        return;
    }

    let mut auth: Option<AuthenticatedSession> = None;
    let mut repository: Option<RedisSyncRepository> = None;
    let mut realtime_receiver = state.realtime.subscribe();

    loop {
        tokio::select! {
            received = socket.recv() => {
                let Some(received) = received else {
                    break;
                };
                let Ok(message) = received else {
                    break;
                };
                let Some(text) = websocket_text(message) else {
                    break;
                };

                if handle_socket_client_packet(
                    &mut socket,
                    &state,
                    &mut auth,
                    &mut repository,
                    &socket_id,
                    &text,
                )
                .await
                    == SocketLoopControl::Close
                {
                    break;
                }
            }
            envelope = realtime_receiver.recv() => {
                match envelope {
                    Ok(envelope) => {
                        if let Some(session) = auth.as_ref() {
                            if send_realtime_envelope(&mut socket, session, &envelope).await.is_err() {
                                break;
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_skipped)) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        break;
                    }
                }
            }
        }
    }

    if let (Some(session), Some(mut redis_repository)) = (auth, repository) {
        let context = socket_presence_context(&socket_id);
        let _clear_result = redis_repository.clear_presence(&session, &context).await;
    }
}

async fn handle_socket_client_packet(
    socket: &mut WebSocket,
    state: &HttpState,
    auth: &mut Option<AuthenticatedSession>,
    repository: &mut Option<RedisSyncRepository>,
    socket_id: &str,
    text: &str,
) -> SocketLoopControl {
    match decode_client_packet(text) {
        ClientPacket::Connect { token } => {
            handle_socket_connect(socket, state, auth, repository, socket_id, &token).await
        }
        ClientPacket::Event { name, payload } => {
            let Some(session) = auth.as_ref() else {
                let _send_result = send_socket_error(socket, "Authentication error").await;
                return SocketLoopControl::Continue;
            };
            let Some(redis_repository) = repository.as_mut() else {
                let _send_result = send_socket_error(socket, "Authentication error").await;
                return SocketLoopControl::Continue;
            };
            if handle_socket_event(
                socket,
                redis_repository,
                session,
                socket_id,
                &name,
                payload.as_ref(),
            )
            .await
            .is_err()
            {
                return SocketLoopControl::Close;
            }
            SocketLoopControl::Continue
        }
        ClientPacket::Ping => {
            if socket
                .send(WebSocketMessage::Text("3".into()))
                .await
                .is_err()
            {
                return SocketLoopControl::Close;
            }
            SocketLoopControl::Continue
        }
        ClientPacket::Pong | ClientPacket::Unknown => SocketLoopControl::Continue,
    }
}

async fn handle_socket_connect(
    socket: &mut WebSocket,
    state: &HttpState,
    auth: &mut Option<AuthenticatedSession>,
    repository: &mut Option<RedisSyncRepository>,
    socket_id: &str,
    token: &str,
) -> SocketLoopControl {
    match socket_authenticate(state, token, socket_id).await {
        Ok((session, redis_repository)) => {
            if socket
                .send(WebSocketMessage::Text(encode_connect_ack().into()))
                .await
                .is_err()
            {
                return SocketLoopControl::Close;
            }
            *auth = Some(session);
            *repository = Some(redis_repository);
            SocketLoopControl::Continue
        }
        Err(message) => {
            let _send_result = send_socket_error(socket, message).await;
            SocketLoopControl::Close
        }
    }
}

async fn socket_authenticate(
    state: &HttpState,
    token: &str,
    socket_id: &str,
) -> Result<(AuthenticatedSession, RedisSyncRepository), &'static str> {
    let Some(sessions) = state.sessions.as_ref() else {
        return Err("Authentication error");
    };
    let Some(pool) = state.pool.clone() else {
        return Err("Authentication error");
    };
    let now_ms = now_millis();
    let session = sessions
        .authenticate_raw_session_token(token, now_ms / 1_000, now_ms)
        .await
        .map_err(|_| "Authentication error")?;
    let mut repository = RedisSyncRepository::connect(pool, &state.redis_sync_config)
        .await
        .map_err(|_| "Authentication error")?;
    let context = socket_presence_context(socket_id);

    repository
        .open_connection(&session, &context)
        .await
        .map_err(|_| "Authentication error")?;

    Ok((session, repository))
}

async fn handle_socket_event(
    socket: &mut WebSocket,
    repository: &mut RedisSyncRepository,
    auth: &AuthenticatedSession,
    socket_id: &str,
    name: &str,
    payload: Option<&serde_json::Value>,
) -> Result<(), ()> {
    if is_plaintext_call_event(name) {
        send_socket_error(socket, "Call signaling moved to E2E message types").await?;
        return Ok(());
    }

    let Some(event) = client_event_from_wire(name) else {
        return Ok(());
    };
    let context = socket_presence_context(socket_id);

    match event {
        ClientEvent::SyncSubscribe => {
            let response = repository.subscribe(auth, &context).await.map_err(|_| ())?;
            send_server_event(socket, ServerEvent::SyncBlobs, &response).await
        }
        ClientEvent::SyncPull => {
            let response = repository
                .pull(
                    auth,
                    &context,
                    socket_pull_limit(sync_pull_limit_payload(payload)),
                )
                .await
                .map_err(|_| ())?;
            send_server_event(socket, ServerEvent::SyncBlobs, &response).await
        }
        ClientEvent::PresenceTouch
        | ClientEvent::JoinConversation
        | ClientEvent::LeaveConversation => repository
            .touch_presence(auth, &context)
            .await
            .map_err(|_| ()),
        ClientEvent::PresenceOffline => repository
            .set_offline_override_and_clear(auth, &context)
            .await
            .map_err(|_| ()),
        ClientEvent::Disconnect => repository
            .clear_presence(auth, &context)
            .await
            .map_err(|_| ()),
    }
}

async fn send_server_event<T: Serialize + Sync>(
    socket: &mut WebSocket,
    event: ServerEvent,
    payload: &T,
) -> Result<(), ()> {
    let packet = encode_server_event(event, payload).map_err(|_| ())?;
    socket
        .send(WebSocketMessage::Text(packet.into()))
        .await
        .map_err(|_| ())
}

async fn send_realtime_envelope(
    socket: &mut WebSocket,
    auth: &AuthenticatedSession,
    envelope: &RealtimeEnvelope,
) -> Result<(), ()> {
    if !envelope.is_visible_to(auth) {
        return Ok(());
    }

    match envelope.payload() {
        RealtimePayload::SyncBlobAvailable(payload) => {
            send_server_event(socket, envelope.event(), payload).await
        }
        RealtimePayload::DeviceLinkRequest(payload) => {
            send_server_event(socket, envelope.event(), payload).await
        }
        RealtimePayload::DeviceLinkApproved(payload) => {
            send_server_event(socket, envelope.event(), payload).await
        }
    }
}

async fn send_socket_error(socket: &mut WebSocket, message: &str) -> Result<(), ()> {
    let packet = encode_error(message).map_err(|_| ())?;
    socket
        .send(WebSocketMessage::Text(packet.into()))
        .await
        .map_err(|_| ())
}

fn websocket_text(message: WebSocketMessage) -> Option<String> {
    match message {
        WebSocketMessage::Text(text) => Some(text.to_string()),
        WebSocketMessage::Binary(bytes) => String::from_utf8(bytes.to_vec()).ok(),
        WebSocketMessage::Close(_) => None,
        WebSocketMessage::Ping(_) | WebSocketMessage::Pong(_) => Some(String::new()),
    }
}

fn socket_presence_context(socket_id: &str) -> SocketPresenceContext {
    SocketPresenceContext {
        socket_id: socket_id.to_owned(),
        timestamp: now_millis().to_string(),
    }
}

fn socket_id() -> Result<String, std::io::Error> {
    let mut bytes = [0_u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|error| std::io::Error::other(error.to_string()))?;

    Ok(base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
        bytes,
    ))
}

async fn axum_health(State(state): State<HttpState>) -> AxumResponse {
    state
        .app
        .handle(&Request::get("/health"))
        .into_axum_response()
}

async fn axum_config(State(state): State<HttpState>) -> AxumResponse {
    state
        .app
        .handle(&Request::get("/api/config"))
        .into_axum_response()
}

async fn axum_auth_register(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
    body: Result<Json<RegisterRequest>, axum::extract::rejection::JsonRejection>,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/auth/register"))
            .into_axum_response();
    }

    if !state.record_auth_hit(
        client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
        now_millis(),
    ) {
        return too_many_requests_response();
    }

    let Some(repository) = state.auth.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/api/auth/register"))
            .into_axum_response();
    };
    let Ok(Json(request)) = body else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid registration payload",
            },
        );
    };
    let server_domain = state.app.config.server_domain().to_owned();

    match repository
        .register(&request, &server_domain, now_millis())
        .await
    {
        Ok(response) => axum_json_response(api_status_code(response.status), &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_auth_start(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
    body: Result<Json<AuthStartRequest>, axum::extract::rejection::JsonRejection>,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/auth/start"))
            .into_axum_response();
    }

    if !state.record_auth_hit(
        client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
        now_millis(),
    ) {
        return too_many_requests_response();
    }

    let Some(repository) = state.auth.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/api/auth/start"))
            .into_axum_response();
    };
    let Ok(Json(request)) = body else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid auth start payload",
            },
        );
    };

    match repository.start(&request, now_millis()).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_auth_finish(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
    body: Result<Json<AuthFinishRequest>, axum::extract::rejection::JsonRejection>,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/auth/finish"))
            .into_axum_response();
    }

    if !state.record_auth_hit(
        client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
        now_millis(),
    ) {
        return too_many_requests_response();
    }

    let Some(repository) = state.auth.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/api/auth/finish"))
            .into_axum_response();
    };
    let Ok(Json(request)) = body else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid auth finish payload",
            },
        );
    };

    match repository.finish(&request, now_millis()).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_auth_refresh(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
    body: Result<Json<RefreshRequest>, axum::extract::rejection::JsonRejection>,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/auth/refresh"))
            .into_axum_response();
    }

    if !state.record_auth_hit(
        client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
        now_millis(),
    ) {
        return too_many_requests_response();
    }

    let Some(repository) = state.auth.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/api/auth/refresh"))
            .into_axum_response();
    };
    let Ok(Json(request)) = body else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid refresh token",
            },
        );
    };

    match repository.refresh(&request, now_millis()).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_auth_logout(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/auth/logout"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.auth.as_ref(), state.sessions.as_ref()) else {
        return state
            .app
            .handle(&Request::new("POST", "/api/auth/logout"))
            .into_axum_response();
    };
    let Ok(request) = parse_logout_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid logout payload",
            },
        );
    };
    let now_ms = now_millis();
    if let Err(error) = sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        return api_error_response(&error);
    }

    match repository
        .logout(authorization_header(&headers), &request, now_ms)
        .await
    {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_message_send(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/messages/send"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.messages.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("POST", "/api/messages/send"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let Ok(request) = parse_message_send_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid message delivery payload",
            },
        );
    };
    let context = MessageSendContext {
        server_domain: Some(state.app.config.server_domain().to_owned()),
        aliases_raw: env::var("SERVER_DOMAIN_ALIASES").ok(),
    };

    match repository.send(&auth, &context, &request, now_ms).await {
        Ok(response) => axum_json_response(StatusCode::ACCEPTED, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_message_ack(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/messages/ack"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.messages.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("POST", "/api/messages/ack"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let Ok(request) = parse_message_ack_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid message ack payload",
            },
        );
    };

    match repository.ack(&auth, &request).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_turn_credentials(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/turn/credentials"))
            .into_axum_response();
    }

    let Some(sessions) = state.sessions.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/api/turn/credentials"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let turn_limit_key = format!("{}:{}", auth.account_id, auth.device_id);
    if !state.record_turn_hit(Some(&turn_limit_key), now_ms) {
        return too_many_requests_response();
    }
    let Ok(request) = parse_turn_credentials_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid TURN credential request",
            },
        );
    };

    match crate::turn::credentials_from_env(&request, now_ms / 1_000) {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_sync_stream(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    query: Result<Query<SyncStreamQuery>, axum::extract::rejection::QueryRejection>,
) -> AxumResponse {
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/sync/stream"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.sync.as_ref(), state.sessions.as_ref()) else {
        return state
            .app
            .handle(&Request::new("GET", "/api/sync/stream"))
            .into_axum_response();
    };
    let Ok(Query(query)) = query else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid sync stream query",
            },
        );
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };

    match repository
        .stream(&auth, &query.into_service_request())
        .await
    {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_media_upload_init(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/media/upload/init"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.media.as_ref(), state.sessions.as_ref()) else {
        return state
            .app
            .handle(&Request::new("POST", "/api/media/upload/init"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let Ok(request) = parse_media_upload_init_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid media upload init payload",
            },
        );
    };

    match repository
        .upload_init(&auth, &request, now_ms, state.app.config.server_domain())
        .await
    {
        Ok(response) => axum_json_response(StatusCode::CREATED, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_media_upload(
    State(state): State<HttpState>,
    Path(media_id): Path<String>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    let route_path = format!("/api/media/upload/{media_id}");
    if method != Method::PUT {
        return state
            .app
            .handle(&Request::new(method.as_str(), route_path))
            .into_axum_response();
    }
    let (Some(repository), Some(object_store), Some(sessions)) = (
        state.media.as_ref(),
        state.media_storage.as_ref(),
        state.sessions.as_ref(),
    ) else {
        return state
            .app
            .handle(&Request::new("PUT", route_path))
            .into_axum_response();
    };

    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };

    process_media_upload(
        repository,
        object_store,
        &state.app.config,
        auth,
        &media_id,
        &headers,
        &body,
    )
    .await
}

async fn process_media_upload(
    repository: &PostgresMediaRepository,
    object_store: &MinioMediaObjectStore,
    config: &Config,
    auth: AuthenticatedSession,
    media_id: &str,
    headers: &HeaderMap,
    body: &Bytes,
) -> AxumResponse {
    if upload_exceeds_limit(body, config.max_upload_bytes()) {
        return axum_json_response(
            StatusCode::PAYLOAD_TOO_LARGE,
            &ErrorResponse {
                error: "Payload too large",
            },
        );
    }
    let media = match load_pending_media_for_upload(repository, &auth, media_id).await {
        Ok(media) => media,
        Err(response) => return response,
    };
    let (attestation, attestation_payload) =
        match validate_media_upload_request(repository, &auth, &media, headers, body).await {
            Ok(validated) => validated,
            Err(response) => return response,
        };

    if object_store
        .put_ciphertext(&media.storage_bucket, &media.storage_key, body)
        .await
        .is_err()
    {
        return internal_error_response();
    }
    if let Err(error) = repository
        .mark_uploaded_verified(&MarkUploadedVerified {
            id: media.id.clone(),
            hash_ciphertext: attestation.ciphertext_sha256.clone(),
            ciphertext_size: body.len(),
            scan_verdict: attestation.scan_verdict.as_wire().to_owned(),
            risk_flags: attestation.risk_flags,
            scanner_version: attestation.scanner_version,
            rules_version: attestation.rules_version,
            signer_user_handle: auth.user_handle,
            signer_device_id: auth.device_id,
            attestation_signature: attestation.attestation_signature,
        })
        .await
    {
        return api_error_response(&error);
    }

    axum_json_response(
        StatusCode::OK,
        &MediaUploadResponse {
            media_id: media.id,
            uploaded: true,
            attestation_payload,
        },
    )
}

async fn load_pending_media_for_upload(
    repository: &PostgresMediaRepository,
    auth: &AuthenticatedSession,
    media_id: &str,
) -> Result<MediaObjectRecord, AxumResponse> {
    let media = match repository.find_media_by_id(media_id).await {
        Ok(Some(media)) => media,
        Ok(None) => return Err(media_not_found_response()),
        Err(error) => return Err(api_error_response(&error)),
    };
    if media.owner_account_id != auth.account_id {
        return Err(axum_json_response(
            StatusCode::FORBIDDEN,
            &ErrorResponse { error: "Forbidden" },
        ));
    }
    if media.status != MediaStatus::Pending {
        return Err(axum_json_response(
            StatusCode::CONFLICT,
            &ErrorResponse {
                error: "Media upload is no longer pending",
            },
        ));
    }

    Ok(media)
}

async fn validate_media_upload_request(
    repository: &PostgresMediaRepository,
    auth: &AuthenticatedSession,
    media: &MediaObjectRecord,
    headers: &HeaderMap,
    body: &Bytes,
) -> Result<(MediaUploadAttestation, String), AxumResponse> {
    if body.is_empty() {
        reject_media_or_response(
            repository,
            &media.id,
            MediaRejectReason::EmptyCiphertextBody.as_wire(),
        )
        .await?;
        return Err(axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Ciphertext body is required",
            },
        ));
    }
    let Some(attestation) = parse_media_upload_attestation(headers) else {
        reject_media_or_response(
            repository,
            &media.id,
            "missing_or_invalid_attestation_headers",
        )
        .await?;
        return Err(axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Secure media attestation is required",
            },
        ));
    };
    let identity_public_key = match repository.identity_public_key(&auth.account_id).await {
        Ok(Some(public_key)) => public_key,
        Ok(None) => {
            reject_media_or_response(repository, &media.id, "missing_identity_key").await?;
            return Err(axum_json_response(
                StatusCode::FORBIDDEN,
                &ErrorResponse {
                    error: "Missing account identity key",
                },
            ));
        }
        Err(error) => return Err(api_error_response(&error)),
    };
    let policy = media_upload_policy();
    let validation = MediaUploadValidationInput {
        media_id: &media.id,
        user_handle: &auth.user_handle,
        device_id: &auth.device_id,
        expected_capability_hash: &media.download_capability_hash,
        ciphertext: body,
        attestation: &attestation,
        min_scanner_version: policy.min_scanner_version,
        min_rules_version: policy.min_rules_version,
        identity_public_key: &identity_public_key,
    };
    let attestation_payload = match validate_media_upload(&validation) {
        Ok(payload) => payload,
        Err(MediaError::Rejected(reason)) => {
            reject_media_or_response(repository, &media.id, reason.as_wire()).await?;
            return Err(api_error_response(&media_rejection_error(reason)));
        }
        Err(MediaError::InvalidVerdict) => {
            reject_media_or_response(
                repository,
                &media.id,
                "missing_or_invalid_attestation_headers",
            )
            .await?;
            return Err(axum_json_response(
                StatusCode::BAD_REQUEST,
                &ErrorResponse {
                    error: "Secure media attestation is required",
                },
            ));
        }
    };

    Ok((attestation, attestation_payload))
}

async fn reject_media_or_response(
    repository: &PostgresMediaRepository,
    media_id: &str,
    reason: &str,
) -> Result<(), AxumResponse> {
    repository
        .mark_rejected(media_id, reason)
        .await
        .map_err(|error| api_error_response(&error))
}

async fn axum_media_download(
    State(state): State<HttpState>,
    Path(media_id): Path<String>,
    method: Method,
    headers: HeaderMap,
) -> AxumResponse {
    let route_path = format!("/api/media/ciphertext/{media_id}");
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), route_path))
            .into_axum_response();
    }

    let (Some(repository), Some(object_store)) =
        (state.media.as_ref(), state.media_storage.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("GET", route_path))
            .into_axum_response();
    };
    let Some(token) = bearer_capability_token(authorization_header(&headers)) else {
        return axum_json_response(
            StatusCode::UNAUTHORIZED,
            &ErrorResponse {
                error: "Missing media capability token",
            },
        );
    };
    let media = match repository
        .find_media_for_capability(&media_id, &hash_capability_token(&token))
        .await
    {
        Ok(Some(media)) => media,
        Ok(None) => {
            return axum_json_response(
                StatusCode::NOT_FOUND,
                &ErrorResponse {
                    error: "Media not found",
                },
            )
        }
        Err(error) => return api_error_response(&error),
    };
    match object_store
        .get_ciphertext(&media.storage_bucket, &media.storage_key)
        .await
    {
        Ok(ciphertext) => ciphertext_bytes_response(ciphertext),
        Err(_error) => axum_json_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            &ErrorResponse {
                error: "Internal server error",
            },
        ),
    }
}

async fn axum_device_register(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/register"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.devices.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("POST", "/api/devices/register"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let Ok(request) = parse_device_register_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid device registration payload",
            },
        );
    };

    match repository.register(&auth, &request, now_ms).await {
        Ok(device) => axum_json_response(StatusCode::CREATED, &DeviceResponse { device: &device }),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_device_revoke(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/revoke"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.devices.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("POST", "/api/devices/revoke"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let Ok(request) = parse_device_revoke_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid device revoke payload",
            },
        );
    };

    match repository.revoke(&auth, &request).await {
        Ok(device) => axum_json_response(StatusCode::OK, &DeviceResponse { device: &device }),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_push_tokens(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if !matches!(method, Method::GET | Method::POST) {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/push/tokens"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.devices.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/push/tokens"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };

    match method {
        Method::GET => match repository.list_push_tokens(&auth).await {
            Ok(response) => axum_json_response(StatusCode::OK, &response),
            Err(error) => api_error_response(&error),
        },
        Method::POST => {
            let Ok(request) = parse_push_token_upsert(&body) else {
                return axum_json_response(
                    StatusCode::BAD_REQUEST,
                    &ErrorResponse {
                        error: "Invalid push token payload",
                    },
                );
            };
            match repository.upsert_push_token(&auth, &request).await {
                Ok(token) => {
                    axum_json_response(StatusCode::CREATED, &PushTokenResponse { token: &token })
                }
                Err(error) => api_error_response(&error),
            }
        }
        _ => unreachable_method_response(),
    }
}

async fn axum_device_link_start(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/link/start"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.device_links.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("POST", "/api/devices/link/start"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let Ok(request) = parse_link_start_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid link session payload",
            },
        );
    };

    match repository.start(&auth, &request, now_ms).await {
        Ok(response) => axum_json_response(StatusCode::CREATED, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_device_link_request(
    State(state): State<HttpState>,
    method: Method,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/link/request"))
            .into_axum_response();
    }

    let Some(repository) = state.device_links.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/api/devices/link/request"))
            .into_axum_response();
    };
    let Ok(request) = parse_link_request_create_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid link request payload",
            },
        );
    };

    match repository.request(&request, now_millis()).await {
        Ok(response) => axum_json_response(StatusCode::ACCEPTED, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_device_link_session_requests(
    State(state): State<HttpState>,
    Path(session_id): Path<String>,
    method: Method,
    headers: HeaderMap,
) -> AxumResponse {
    let route_path = format!("/api/devices/link/session/{session_id}/requests");
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), route_path))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.device_links.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("GET", route_path))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };

    match repository.list_requests(&auth, &session_id).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_device_link_request_item(
    State(state): State<HttpState>,
    Path(request_id): Path<String>,
    Query(query): Query<LinkPollQuery>,
    method: Method,
) -> AxumResponse {
    let route_path = format!("/api/devices/link/request/{request_id}");
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), route_path))
            .into_axum_response();
    }

    let Some(repository) = state.device_links.as_ref() else {
        return state
            .app
            .handle(&Request::new("GET", route_path))
            .into_axum_response();
    };
    let poll_token = query.poll_token.unwrap_or_default();

    match repository.poll(&request_id, &poll_token).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_device_link_approve(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/link/approve"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.device_links.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("POST", "/api/devices/link/approve"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    let Ok(request) = parse_link_approve_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid link approval payload",
            },
        );
    };

    match repository.approve(&auth, &request, now_ms).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_device_link_complete(
    State(state): State<HttpState>,
    method: Method,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/devices/link/complete"))
            .into_axum_response();
    }

    let Some(repository) = state.device_links.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/api/devices/link/complete"))
            .into_axum_response();
    };
    let Ok(request) = parse_link_complete_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid link completion payload",
            },
        );
    };

    match repository.complete(&request, now_millis()).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_push_token_item(
    State(state): State<HttpState>,
    Path(token): Path<String>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if !matches!(method, Method::PUT | Method::DELETE) {
        return state
            .app
            .handle(&Request::new(
                method.as_str(),
                format!("/api/devices/push/tokens/{token}"),
            ))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.devices.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new(
                method.as_str(),
                format!("/api/devices/push/tokens/{token}"),
            ))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };

    match method {
        Method::PUT => {
            let Ok(request) = parse_push_token_update(&body) else {
                return axum_json_response(
                    StatusCode::BAD_REQUEST,
                    &ErrorResponse {
                        error: "Invalid push token update",
                    },
                );
            };
            match repository.update_push_token(&auth, &token, &request).await {
                Ok(token) => {
                    axum_json_response(StatusCode::OK, &PushTokenResponse { token: &token })
                }
                Err(error) => api_error_response(&error),
            }
        }
        Method::DELETE => match repository.delete_push_token(&auth, &token).await {
            Ok(()) => no_content_response(),
            Err(error) => api_error_response(&error),
        },
        _ => unreachable_method_response(),
    }
}

async fn axum_prekey_lookup(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
    Query(query): Query<PrekeyLookupQuery>,
) -> AxumResponse {
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/prekeys/get"))
            .into_axum_response();
    }

    let now_ms = now_millis();
    if !should_bypass_public_directory_limit(&state, &headers, "/api/prekeys/get", now_ms).await
        && !state.record_public_directory_hit(
            client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
            now_ms,
        )
    {
        return too_many_requests_response();
    }

    let Some(repository) = state.prekeys.as_ref() else {
        return state
            .app
            .handle(&Request::get("/api/prekeys/get"))
            .into_axum_response();
    };

    match repository.lookup(&query.into_service_request()).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_prekey_self(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    Query(query): Query<SelfPrekeyQuery>,
) -> AxumResponse {
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/prekeys/self"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.prekeys.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::get("/api/prekeys/self"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };

    match repository
        .lookup_self(&auth, &query.into_service_request())
        .await
    {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_prekey_publish(
    State(state): State<HttpState>,
    method: Method,
    headers: HeaderMap,
    body: Result<Json<PrekeyPublishRequest>, axum::extract::rejection::JsonRejection>,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/api/prekeys/publish"))
            .into_axum_response();
    }

    let (Some(repository), Some(sessions)) = (state.prekeys.as_ref(), state.sessions.as_ref())
    else {
        return state
            .app
            .handle(&Request::new("POST", "/api/prekeys/publish"))
            .into_axum_response();
    };
    let Ok(Json(request)) = body else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid prekey payload",
            },
        );
    };
    let now_ms = now_millis();
    let auth = match sessions
        .authenticate_session(authorization_header(&headers), now_ms / 1_000, now_ms)
        .await
    {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };

    match repository.publish(&auth, &request).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_federation_server_keys(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
) -> AxumResponse {
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/federation/v1/server-keys"))
            .into_axum_response();
    }

    if !state.record_public_directory_hit(
        client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
        now_millis(),
    ) {
        return too_many_requests_response();
    }

    if state.federation.is_none() {
        return state
            .app
            .handle(&Request::get("/federation/v1/server-keys"))
            .into_axum_response();
    }

    match PostgresFederationRepository::server_keys(state.app.config.server_domain(), now_millis())
    {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_federation_prekeys(
    State(state): State<HttpState>,
    Path(user_handle): Path<String>,
    method: Method,
    Query(query): Query<FederationPrekeyQuery>,
) -> AxumResponse {
    let route_path = format!("/federation/v1/prekeys/{user_handle}");
    if method != Method::GET {
        return state
            .app
            .handle(&Request::new(method.as_str(), route_path))
            .into_axum_response();
    }

    let Some(repository) = state.federation.as_ref() else {
        return state
            .app
            .handle(&Request::new("GET", route_path))
            .into_axum_response();
    };

    match repository
        .prekeys(&query.into_service_request(user_handle))
        .await
    {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_federation_deliver(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/federation/v1/deliver"))
            .into_axum_response();
    }

    let Some(repository) = state.federation.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/federation/v1/deliver"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    if !state.record_federation_preauth_hit(
        client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
        now_ms,
    ) {
        return too_many_requests_response();
    }

    let Ok(body_raw) = std::str::from_utf8(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid federation delivery payload",
            },
        );
    };
    let header_values = federation_header_values(&headers);
    let auth_request = federation_auth_request(
        "POST",
        "/federation/v1/deliver",
        body_raw,
        &header_values,
        now_ms,
    );
    let auth = match repository.authenticate(&auth_request).await {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    if !state.record_federation_domain_hit(Some(&auth.server_domain), now_ms) {
        return too_many_requests_response();
    }

    let Ok(request) = parse_federation_deliver_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid federation delivery payload",
            },
        );
    };

    match repository.deliver(&auth, &request, now_ms).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_federation_receipts(
    State(state): State<HttpState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> AxumResponse {
    if method != Method::POST {
        return state
            .app
            .handle(&Request::new(method.as_str(), "/federation/v1/receipts"))
            .into_axum_response();
    }

    let Some(repository) = state.federation.as_ref() else {
        return state
            .app
            .handle(&Request::new("POST", "/federation/v1/receipts"))
            .into_axum_response();
    };
    let now_ms = now_millis();
    if !state.record_federation_preauth_hit(
        client_rate_limit_key(&headers, Some(peer_addr)).as_deref(),
        now_ms,
    ) {
        return too_many_requests_response();
    }

    let Ok(body_raw) = std::str::from_utf8(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid federation receipt payload",
            },
        );
    };
    let header_values = federation_header_values(&headers);
    let auth_request = federation_auth_request(
        "POST",
        "/federation/v1/receipts",
        body_raw,
        &header_values,
        now_ms,
    );
    let auth = match repository.authenticate(&auth_request).await {
        Ok(auth) => auth,
        Err(error) => return api_error_response(&error),
    };
    if !state.record_federation_domain_hit(Some(&auth.server_domain), now_ms) {
        return too_many_requests_response();
    }

    let Ok(request) = parse_federation_receipts_request(&body) else {
        return axum_json_response(
            StatusCode::BAD_REQUEST,
            &ErrorResponse {
                error: "Invalid federation receipt payload",
            },
        );
    };

    match repository.receipts(&auth, &request).await {
        Ok(response) => axum_json_response(StatusCode::OK, &response),
        Err(error) => api_error_response(&error),
    }
}

async fn axum_dispatch(State(state): State<HttpState>, method: Method, uri: Uri) -> AxumResponse {
    let path = uri
        .path_and_query()
        .map_or_else(|| uri.path(), axum::http::uri::PathAndQuery::as_str);
    let request = Request::new(method.as_str(), path);
    state.app.handle(&request).into_axum_response()
}

fn handle_stream(stream: &mut TcpStream, app: &Application) -> Result<(), ServerError> {
    if let Some(request) = read_request(stream)? {
        let response = app.handle(&request);
        stream.write_all(&response.to_http_bytes())?;
        stream.flush()?;
    }

    Ok(())
}

fn read_request(stream: &mut TcpStream) -> Result<Option<Request>, ServerError> {
    let mut buffer = vec![0_u8; 8_192];
    let read = stream.read(&mut buffer)?;
    if read == 0 {
        return Ok(None);
    }

    buffer.truncate(read);
    let text = String::from_utf8_lossy(&buffer);
    let request_line = text.lines().next().unwrap_or_default();
    let mut parts = request_line.split_ascii_whitespace();
    let Some(method) = parts.next() else {
        return Ok(None);
    };
    let Some(path) = parts.next() else {
        return Ok(None);
    };

    Ok(Some(Request::new(method, path)))
}

fn read_u64_env(name: &str, default_value: u64) -> Result<u64, ConfigError> {
    let Ok(value) = env::var(name) else {
        return Ok(default_value);
    };

    value.parse::<u64>().map_err(|_| ConfigError::Number {
        name: name.to_owned(),
        value,
    })
}

fn is_valid_domain(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b':'))
}

fn json_response<T: Serialize>(status: Status, body: &T) -> Response {
    match serde_json::to_string(body) {
        Ok(body) => Response::json(status, body),
        Err(_error) => Response::json(
            Status::InternalServerError,
            "{\"error\":\"Internal server error\"}".to_owned(),
        ),
    }
}

fn axum_json_response<T: Serialize>(status: StatusCode, body: &T) -> AxumResponse {
    match serde_json::to_string(body) {
        Ok(body) => (
            status,
            [
                ("content-type", "application/json"),
                ("cache-control", "no-store"),
            ],
            body,
        )
            .into_response(),
        Err(_error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            [
                ("content-type", "application/json"),
                ("cache-control", "no-store"),
            ],
            "{\"error\":\"Internal server error\"}",
        )
            .into_response(),
    }
}

fn api_error_response(error: &auth_service::ApiError) -> AxumResponse {
    let status = StatusCode::from_u16(error.status().code())
        .map_or(StatusCode::INTERNAL_SERVER_ERROR, |status| status);
    axum_json_response(status, error)
}

fn api_status_code(status: auth_service::ApiStatus) -> StatusCode {
    StatusCode::from_u16(status.code()).map_or(StatusCode::INTERNAL_SERVER_ERROR, |status| status)
}

fn too_many_requests_response() -> AxumResponse {
    match serde_json::to_string(&ErrorResponse {
        error: too_many_requests_error(),
    }) {
        Ok(body) => (
            StatusCode::TOO_MANY_REQUESTS,
            [
                ("content-type", "application/json"),
                ("cache-control", "no-store"),
                ("retry-after", "60"),
                ("x-ratelimit-window-seconds", "60"),
            ],
            body,
        )
            .into_response(),
        Err(_error) => internal_error_response(),
    }
}

fn no_content_response() -> AxumResponse {
    (
        StatusCode::NO_CONTENT,
        [("cache-control", "no-store")],
        String::new(),
    )
        .into_response()
}

fn internal_error_response() -> AxumResponse {
    axum_json_response(
        StatusCode::INTERNAL_SERVER_ERROR,
        &ErrorResponse {
            error: "Internal server error",
        },
    )
}

fn media_not_found_response() -> AxumResponse {
    axum_json_response(
        StatusCode::NOT_FOUND,
        &ErrorResponse {
            error: "Media not found",
        },
    )
}

fn unreachable_method_response() -> AxumResponse {
    axum_json_response(
        StatusCode::METHOD_NOT_ALLOWED,
        &ErrorResponse {
            error: "Method not allowed",
        },
    )
}

fn upload_exceeds_limit(body: &Bytes, max_upload_bytes: u64) -> bool {
    u64::try_from(body.len()).map_or(true, |value| value > max_upload_bytes)
}

fn record_limited_hit(
    limits: &Mutex<BTreeMap<String, CounterState>>,
    raw_key: Option<&str>,
    now_ms: u64,
    limit: u64,
) -> bool {
    let Some(key) = normalize_key(raw_key) else {
        return true;
    };
    let Ok(mut limits) = limits.lock() else {
        return false;
    };
    let current = limits.get(&key).copied();
    let decision = record_window_hit(current, now_ms, limit);

    match decision {
        RateLimitDecision::Allow(next) => {
            limits.insert(key, next);
            true
        }
        RateLimitDecision::Throttle(_) => false,
    }
}

fn client_rate_limit_key(headers: &HeaderMap, peer_addr: Option<SocketAddr>) -> Option<String> {
    forwarded_header(headers)
        .or_else(|| single_header(headers, "x-real-ip"))
        .or_else(|| peer_addr.map(|addr| addr.ip().to_string()))
        .or_else(|| Some("unknown".to_owned()))
}

async fn should_bypass_public_directory_limit(
    state: &HttpState,
    headers: &HeaderMap,
    path: &str,
    now_ms: u64,
) -> bool {
    let Some(sessions) = state.sessions.as_ref() else {
        return false;
    };
    let Ok(auth) = sessions
        .authenticate_session(authorization_header(headers), now_ms / 1_000, now_ms)
        .await
    else {
        return false;
    };

    bypass_for_session_claims(path, TokenKind::Session, &auth.user_handle)
}

fn forwarded_header(headers: &HeaderMap) -> Option<String> {
    let raw = single_header(headers, "x-forwarded-for")?;
    raw.split(',')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn single_header(headers: &HeaderMap, name: &'static str) -> Option<String> {
    headers
        .get(name)?
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn authorization_header(headers: &HeaderMap) -> Option<&str> {
    headers.get("authorization")?.to_str().ok()
}

fn ciphertext_bytes_response(ciphertext: Vec<u8>) -> AxumResponse {
    let mut response = (StatusCode::OK, ciphertext).into_response();
    for (name, value) in ciphertext_response_headers() {
        let header_name = axum::http::HeaderName::from_bytes(name.as_bytes());
        let header_value = axum::http::HeaderValue::from_str(value);
        if let (Ok(header_name), Ok(header_value)) = (header_name, header_value) {
            response.headers_mut().insert(header_name, header_value);
        }
    }

    response
}

fn parse_media_upload_attestation(headers: &HeaderMap) -> Option<MediaUploadAttestation> {
    let capability_token = bounded_header(headers, "x-media-download-capability", 24, 512)?;
    let ciphertext_sha256 =
        bounded_header(headers, "x-media-ciphertext-sha256", 64, 64)?.to_ascii_lowercase();
    if !is_sha256_hex(&ciphertext_sha256) {
        return None;
    }
    let verdict =
        parse_media_scan_verdict(&single_header(headers, "x-media-scan-verdict")?).ok()?;
    let raw_risk_flags = single_header(headers, "x-media-risk-flags").unwrap_or_default();
    let risk_flags = canonicalize_risk_flags(
        &raw_risk_flags
            .split(',')
            .map(str::to_owned)
            .collect::<Vec<_>>(),
    );
    let scanner_version = positive_header_u64(headers, "x-media-scanner-version")?;
    let rules_version = positive_header_u64(headers, "x-media-rules-version")?;
    let attestation_signature =
        bounded_header(headers, "x-media-attestation-signature", 16, 8_192)?;

    Some(MediaUploadAttestation {
        capability_token,
        ciphertext_sha256,
        scan_verdict: verdict,
        risk_flags,
        scanner_version,
        rules_version,
        attestation_signature,
    })
}

fn bounded_header(
    headers: &HeaderMap,
    name: &'static str,
    min_len: usize,
    max_len: usize,
) -> Option<String> {
    single_header(headers, name).filter(|value| (min_len..=max_len).contains(&value.len()))
}

fn positive_header_u64(headers: &HeaderMap, name: &'static str) -> Option<u64> {
    single_header(headers, name)?
        .parse::<u64>()
        .ok()
        .filter(|value| *value > 0)
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FederationHeaderValues {
    server: String,
    key_id: String,
    date: String,
    signature: String,
    body_sha256: String,
}

impl FederationHeaderValues {
    fn as_headers(&self) -> FederationHeaders<'_> {
        FederationHeaders {
            x_mesh_server: &self.server,
            x_mesh_key_id: &self.key_id,
            x_mesh_date: &self.date,
            x_mesh_signature: &self.signature,
            x_mesh_body_sha256: &self.body_sha256,
        }
    }
}

fn federation_header_values(headers: &HeaderMap) -> FederationHeaderValues {
    FederationHeaderValues {
        server: single_header(headers, "x-mesh-server").unwrap_or_default(),
        key_id: single_header(headers, "x-mesh-key-id").unwrap_or_default(),
        date: single_header(headers, "x-mesh-date").unwrap_or_default(),
        signature: single_header(headers, "x-mesh-signature").unwrap_or_default(),
        body_sha256: single_header(headers, "x-mesh-body-sha256").unwrap_or_default(),
    }
}

fn federation_auth_request<'a>(
    method: &'a str,
    path: &'a str,
    body_raw: &'a str,
    headers: &'a FederationHeaderValues,
    now_ms: u64,
) -> FederationAuthRequest<'a> {
    FederationAuthRequest {
        method,
        path,
        body_raw,
        headers: headers.as_headers(),
        now_ms,
    }
}

fn parse_logout_request(body: &[u8]) -> Result<LogoutRequest, ()> {
    if body.is_empty() {
        return Ok(LogoutRequest {
            session_token: None,
            refresh_token: None,
        });
    }

    serde_json::from_slice::<LogoutRequest>(body).map_err(|_| ())
}

fn parse_message_send_request(body: &[u8]) -> Result<MessageSendRequest, ()> {
    serde_json::from_slice::<MessageSendRequest>(body).map_err(|_| ())
}

fn parse_message_ack_request(body: &[u8]) -> Result<MessageAckRequest, ()> {
    serde_json::from_slice::<MessageAckRequest>(body).map_err(|_| ())
}

fn parse_media_upload_init_request(body: &[u8]) -> Result<MediaUploadInitRequest, ()> {
    if body.is_empty() {
        return Ok(MediaUploadInitRequest {
            mime_hint: None,
            size_hint: None,
            ttl_sec: None,
        });
    }

    serde_json::from_slice::<MediaUploadInitRequest>(body).map_err(|_| ())
}

fn parse_federation_deliver_request(body: &[u8]) -> Result<FederationDeliverRequest, ()> {
    serde_json::from_slice::<FederationDeliverRequest>(body).map_err(|_| ())
}

fn parse_federation_receipts_request(body: &[u8]) -> Result<FederationReceiptsRequest, ()> {
    serde_json::from_slice::<FederationReceiptsRequest>(body).map_err(|_| ())
}

fn parse_device_register_request(body: &[u8]) -> Result<DeviceRegisterRequest, ()> {
    serde_json::from_slice::<DeviceRegisterRequest>(body).map_err(|_| ())
}

fn parse_device_revoke_request(body: &[u8]) -> Result<DeviceRevokeRequest, ()> {
    serde_json::from_slice::<DeviceRevokeRequest>(body).map_err(|_| ())
}

fn parse_link_start_request(body: &[u8]) -> Result<LinkStartRequest, ()> {
    serde_json::from_slice::<LinkStartRequest>(body).map_err(|_| ())
}

fn parse_link_request_create_request(body: &[u8]) -> Result<LinkRequestCreateRequest, ()> {
    serde_json::from_slice::<LinkRequestCreateRequest>(body).map_err(|_| ())
}

fn parse_link_approve_request(body: &[u8]) -> Result<LinkApproveRequest, ()> {
    serde_json::from_slice::<LinkApproveRequest>(body).map_err(|_| ())
}

fn parse_link_complete_request(body: &[u8]) -> Result<LinkCompleteRequest, ()> {
    serde_json::from_slice::<LinkCompleteRequest>(body).map_err(|_| ())
}

fn parse_push_token_upsert(body: &[u8]) -> Result<PushTokenUpsert, ()> {
    serde_json::from_slice::<PushTokenUpsert>(body).map_err(|_| ())
}

fn parse_push_token_update(body: &[u8]) -> Result<PushTokenUpdate, ()> {
    serde_json::from_slice::<PushTokenUpdate>(body).map_err(|_| ())
}

fn parse_turn_credentials_request(body: &[u8]) -> Result<TurnCredentialsRequest, ()> {
    serde_json::from_slice::<TurnCredentialsRequest>(body).map_err(|_| ())
}

fn auth_rate_limit_per_minute() -> u64 {
    positive_u64_env("AUTH_RATE_LIMIT_PER_MINUTE", AUTH_RATE_LIMIT_PER_MINUTE)
}

fn public_directory_rate_limit_per_minute() -> u64 {
    positive_u64_env(
        "PUBLIC_DIRECTORY_RATE_LIMIT_PER_MINUTE",
        PUBLIC_DIRECTORY_RATE_LIMIT_PER_MINUTE,
    )
}

fn media_upload_policy() -> MediaUploadPolicy {
    MediaUploadPolicy {
        min_scanner_version: positive_u64_env("MEDIA_MIN_SCANNER_VERSION", 1),
        min_rules_version: positive_u64_env("MEDIA_MIN_RULES_VERSION", 1),
    }
}

fn federation_preauth_rate_limit_per_minute() -> u64 {
    positive_u64_env(
        "FEDERATION_PREAUTH_RATE_LIMIT_PER_MINUTE",
        FEDERATION_PREAUTH_RATE_LIMIT_PER_MINUTE,
    )
}

fn federation_rate_limit_per_minute() -> u64 {
    positive_u64_env(
        "FEDERATION_RATE_LIMIT_PER_MINUTE",
        FEDERATION_RATE_LIMIT_PER_MINUTE,
    )
}

fn turn_credentials_rate_limit_per_minute() -> u64 {
    positive_u64_env("TURN_CREDENTIALS_RATE_LIMIT_PER_MINUTE", 30)
}

fn positive_u64_env(name: &str, fallback: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(fallback)
}

fn now_millis() -> u64 {
    let Ok(duration) = SystemTime::now().duration_since(UNIX_EPOCH) else {
        return 0;
    };

    u64::try_from(duration.as_millis()).map_or(u64::MAX, |value| value)
}

fn path_without_query(path: &str) -> &str {
    path.split_once('?').map_or(path, |(plain, _query)| plain)
}

fn matches_contract_route(method: &str, path: &str) -> bool {
    ROUTES
        .iter()
        .any(|route| route.method == method && route_pattern_matches(route.path, path))
}

fn matches_contract_path(path: &str) -> bool {
    ROUTES
        .iter()
        .any(|route| route_pattern_matches(route.path, path))
}

fn route_pattern_matches(pattern: &str, path: &str) -> bool {
    let pattern_segments: Vec<&str> = pattern.split('/').collect();
    let path_segments: Vec<&str> = path.split('/').collect();
    pattern_segments.len() == path_segments.len()
        && pattern_segments.iter().zip(path_segments.iter()).all(
            |(pattern_segment, path_segment)| {
                pattern_segment
                    .strip_prefix(':')
                    .is_some_and(|_| !path_segment.is_empty())
                    || pattern_segment == path_segment
            },
        )
}

#[cfg(test)]
mod tests {
    use super::{
        authorization_header, client_rate_limit_key, parse_device_register_request,
        parse_device_revoke_request, parse_federation_deliver_request,
        parse_federation_receipts_request, parse_link_approve_request, parse_link_complete_request,
        parse_link_request_create_request, parse_link_start_request, parse_logout_request,
        parse_media_upload_attestation, parse_media_upload_init_request, parse_message_ack_request,
        parse_message_send_request, parse_push_token_update, parse_push_token_upsert,
        parse_turn_credentials_request, record_limited_hit, Application, Config,
        FederationPrekeyQuery, HttpState, LinkPollQuery, PrekeyLookupQuery, Request,
        SelfPrekeyQuery, ShutdownHandle, SocketAddr, Status, SyncStreamQuery,
    };
    use crate::contract::ROUTES;
    use crate::media::MediaScanVerdict;
    use axum::http::{HeaderMap, HeaderValue};
    use std::time::Duration;

    fn test_config() -> Config {
        Config::new(
            SocketAddr::from(([127, 0, 0, 1], 0)),
            "example.invalid".to_owned(),
            10_485_760,
            Duration::from_millis(0),
        )
    }

    fn test_app() -> Application {
        Application::new(test_config())
    }

    #[test]
    fn health_response_is_stable() {
        let response = test_app().handle(&Request::get("/health"));
        assert_eq!(response.status(), Status::Ok);
        assert_eq!(
            response.body(),
            "{\"status\":\"ok\",\"service\":\"tellme-rust\",\"version\":\"2.0.0\"}"
        );
    }

    #[test]
    fn public_config_keeps_call_signaling_encrypted() {
        let response = test_app().handle(&Request::get("/api/config"));
        assert_eq!(response.status(), Status::Ok);
        assert!(response
            .body()
            .contains("\"call_signaling\":\"e2e_message_payload\""));
        assert!(response
            .body()
            .contains("\"media_transport\":\"webrtc_turn_relay\""));
        assert!(response
            .body()
            .contains("\"direct_webrtc\":\"disabled_release_1\""));
    }

    #[test]
    fn unknown_routes_keep_json_error_shape() {
        let response = test_app().handle(&Request::get("/api/calls"));
        assert_eq!(response.status(), Status::NotFound);
        assert_eq!(response.body(), "{\"error\":\"Not found\"}");
    }

    #[test]
    fn frozen_contract_routes_are_visible_at_http_surface() {
        for route in ROUTES {
            let response = test_app().handle(&Request::new(route.method, sample_path(route.path)));
            assert_eq!(response.status(), Status::NotImplemented);
            assert_eq!(
                response.body(),
                "{\"error\":\"Rust route awaits persistence adapter\"}"
            );
        }
    }

    #[test]
    fn route_surface_handles_query_strings_and_method_mismatch() {
        let response = test_app().handle(&Request::get("/api/prekeys/get?user=@a:b&peek=true"));
        assert_eq!(response.status(), Status::NotImplemented);

        let response = test_app().handle(&Request::new("GET", "/api/auth/start"));
        assert_eq!(response.status(), Status::MethodNotAllowed);
        assert_eq!(response.body(), "{\"error\":\"Method not allowed\"}");
    }

    #[test]
    fn shutdown_handle_is_cooperative() {
        let handle = ShutdownHandle::new();
        assert!(!handle.is_requested());
        handle.request();
        assert!(handle.is_requested());
    }

    #[test]
    fn prekey_lookup_query_matches_current_peek_semantics() {
        let query = PrekeyLookupQuery {
            user: Some(" @Alice:Example.COM ".to_owned()),
            device_id: Some("ios-primary".to_owned()),
            peek: Some(" TRUE ".to_owned()),
        };

        let request = query.into_service_request();

        assert_eq!(request.user.as_deref(), Some(" @Alice:Example.COM "));
        assert_eq!(request.device_id.as_deref(), Some("ios-primary"));
        assert!(request.peek);
    }

    #[test]
    fn self_prekey_query_matches_current_peek_semantics() {
        let query = SelfPrekeyQuery {
            device_id: Some("ios-primary".to_owned()),
            peek: Some("1".to_owned()),
        };

        let request = query.into_service_request();

        assert_eq!(request.device_id.as_deref(), Some("ios-primary"));
        assert!(!request.peek);
    }

    #[test]
    fn sync_stream_query_maps_to_service_request() {
        let query = SyncStreamQuery {
            limit: Some(50),
            device_id: Some("ios-secondary".to_owned()),
        };

        let request = query.into_service_request();

        assert_eq!(request.limit, Some(50));
        assert_eq!(request.device_id.as_deref(), Some("ios-secondary"));
    }

    #[test]
    fn federation_prekey_query_matches_current_peek_semantics() {
        let query = FederationPrekeyQuery {
            device_id: Some("ios-primary".to_owned()),
            peek: Some("true".to_owned()),
        };

        let request = query.into_service_request("@alice:Example.COM".to_owned());

        assert_eq!(request.user_handle, "@alice:Example.COM");
        assert_eq!(request.device_id.as_deref(), Some("ios-primary"));
        assert!(request.peek);
    }

    #[test]
    fn public_directory_key_prefers_forwarded_client_ip() {
        let mut headers = HeaderMap::new();
        let forwarded = HeaderValue::from_str("203.0.113.7, 198.51.100.4");
        assert!(forwarded.is_ok());
        let Ok(forwarded) = forwarded else {
            return;
        };
        headers.insert("x-forwarded-for", forwarded);

        assert_eq!(
            client_rate_limit_key(&headers, Some(SocketAddr::from(([10, 0, 0, 5], 4321))))
                .as_deref(),
            Some("203.0.113.7")
        );

        let empty = HeaderMap::new();
        assert_eq!(
            client_rate_limit_key(&empty, Some(SocketAddr::from(([10, 0, 0, 5], 4321)))).as_deref(),
            Some("10.0.0.5")
        );
        assert_eq!(
            client_rate_limit_key(&empty, None).as_deref(),
            Some("unknown")
        );
    }

    #[test]
    fn authorization_header_is_never_synthesized() {
        let mut headers = HeaderMap::new();
        let bearer = HeaderValue::from_str("Bearer session-token");
        assert!(bearer.is_ok());
        let Ok(bearer) = bearer else {
            return;
        };
        headers.insert("authorization", bearer);

        assert_eq!(authorization_header(&headers), Some("Bearer session-token"));
        assert_eq!(authorization_header(&HeaderMap::new()), None);
    }

    #[test]
    fn logout_request_accepts_empty_or_explicit_tokens() {
        let empty = parse_logout_request(b"");
        assert!(empty.is_ok());
        let Ok(empty) = empty else {
            return;
        };
        assert_eq!(empty.session_token, None);
        assert_eq!(empty.refresh_token, None);

        let parsed = parse_logout_request(
            br#"{"session_token":"session-token","refresh_token":"refresh-token"}"#,
        );
        assert!(parsed.is_ok());
        let Ok(parsed) = parsed else {
            return;
        };
        assert_eq!(parsed.session_token.as_deref(), Some("session-token"));
        assert_eq!(parsed.refresh_token.as_deref(), Some("refresh-token"));
        assert!(parse_logout_request(b"not json").is_err());
    }

    #[test]
    fn message_requests_parse_after_session_auth_boundary() {
        let send = parse_message_send_request(
            br#"{
              "deliveries": [{
                "wire_version": 2,
                "delivery_id": "22222222-2222-4222-8222-222222222222",
                "to_server": "example.invalid",
                "to_user": "@bob:example.invalid",
                "to_device_id": "ios-primary",
                "message_id": "11111111-1111-4111-8111-111111111111",
                "timestamp": "2026-02-26T12:00:00.000Z",
                "ttl_sec": 600,
                "ciphertext_blob": "opaque-ciphertext",
                "push_kind": "call"
              }]
            }"#,
        );
        assert!(send.is_ok());

        let ack =
            parse_message_ack_request(br#"{"msg_ids":["11111111-1111-4111-8111-111111111111"]}"#);
        assert!(ack.is_ok());
        assert!(parse_message_send_request(b"").is_err());
        assert!(parse_message_ack_request(b"not json").is_err());
    }

    #[test]
    fn media_upload_init_accepts_empty_or_explicit_payload() {
        let empty = parse_media_upload_init_request(b"");
        assert!(empty.is_ok());
        let Ok(empty) = empty else {
            return;
        };
        assert_eq!(empty.mime_hint, None);
        assert_eq!(empty.size_hint, None);
        assert_eq!(empty.ttl_sec, None);

        let explicit = parse_media_upload_init_request(
            br#"{"mime_hint":"application/octet-stream","size_hint":15,"ttl_sec":600}"#,
        );
        assert!(explicit.is_ok());
        assert!(parse_media_upload_init_request(b"not json").is_err());
    }

    #[test]
    fn media_upload_attestation_headers_match_current_route_schema() {
        let mut headers = HeaderMap::new();
        insert_header(
            &mut headers,
            "x-media-download-capability",
            "capability-token-1234567890abcdef",
        );
        insert_header(
            &mut headers,
            "x-media-ciphertext-sha256",
            "1423D4E5BC2D4BC05052A8730017FE1430EACEA29D957DFB3BDA299FA1587064",
        );
        insert_header(&mut headers, "x-media-scan-verdict", "WARN");
        insert_header(
            &mut headers,
            "x-media-risk-flags",
            " pdf_active_content,PDF_ACTIVE_CONTENT ",
        );
        insert_header(&mut headers, "x-media-scanner-version", "1");
        insert_header(&mut headers, "x-media-rules-version", "2");
        insert_header(
            &mut headers,
            "x-media-attestation-signature",
            "signature-material",
        );

        let parsed = parse_media_upload_attestation(&headers);

        assert!(parsed.is_some());
        let Some(parsed) = parsed else {
            return;
        };
        assert_eq!(parsed.scan_verdict, MediaScanVerdict::Warn);
        assert_eq!(
            parsed.ciphertext_sha256,
            "1423d4e5bc2d4bc05052a8730017fe1430eacea29d957dfb3bda299fa1587064"
        );
        assert_eq!(parsed.risk_flags, vec!["pdf_active_content".to_owned()]);

        insert_header(&mut headers, "x-media-ciphertext-sha256", "not-hex");
        assert!(parse_media_upload_attestation(&headers).is_none());
    }

    #[test]
    fn federation_requests_parse_after_signature_boundary() {
        let deliver = parse_federation_deliver_request(
            br#"{
              "from_server": "remote.example",
              "deliveries": [{
                "wire_version": 2,
                "delivery_id": "22222222-2222-4222-8222-222222222222",
                "to_server": "example.invalid",
                "to_user": "@bob:example.invalid",
                "to_device_id": "*",
                "message_id": "11111111-1111-4111-8111-111111111111",
                "timestamp": "2026-02-26T12:00:00.000Z",
                "ttl_sec": 600,
                "ciphertext_blob": "opaque-ciphertext",
                "push_kind": "call_missed"
              }]
            }"#,
        );
        assert!(deliver.is_ok());

        let receipts = parse_federation_receipts_request(
            br#"{"receipts":[{"message_id":"11111111-1111-4111-8111-111111111111","delivery_id":"22222222-2222-4222-8222-222222222222","status":"acked"}]}"#,
        );
        assert!(receipts.is_ok());
        assert!(parse_federation_deliver_request(b"").is_err());
        assert!(parse_federation_receipts_request(b"not json").is_err());
    }

    #[test]
    fn device_requests_parse_after_session_auth_boundary() {
        let register = parse_device_register_request(
            br#"{
              "device_pub_keys": {
                "device_id": "ios-linked",
                "dk_sign_pub": "sign-pub",
                "dk_dh_pub": "dh-pub"
              },
              "device_certificate_chain": [{
                "device_certificate_version": 2,
                "account_handle": "@alice:example.invalid",
                "device_id": "ios-linked",
                "device_sign_pub": "sign-pub",
                "device_dh_pub": "dh-pub",
                "issuer_kind": "account",
                "issued_at": "2026-02-26T12:00:00.000Z",
                "signature": "sig"
              }]
            }"#,
        );
        assert!(register.is_ok());

        let revoke = parse_device_revoke_request(
            br#"{"device_id":"ios-linked","signature":"sig","timestamp":"2026-02-26T12:00:00.000Z"}"#,
        );
        assert!(revoke.is_ok());
        assert!(parse_device_register_request(b"").is_err());
        assert!(parse_device_revoke_request(b"not json").is_err());
    }

    #[test]
    fn device_link_start_and_request_parse_at_route_boundaries() {
        let start = parse_link_start_request(
            br#"{
              "link_code": "link-code-123456",
              "l_dh_pub": "host-link-dh",
              "expires_in_sec": 300
            }"#,
        );
        assert!(start.is_ok());

        let request = parse_link_request_create_request(
            br#"{
              "user_handle": "@alice:example.invalid",
              "link_code": "link-code-123456",
              "n_dh_pub": "new-link-dh",
              "device_pub_keys": {
                "device_id": "ios-linked",
                "dk_sign_pub": "sign-pub",
                "dk_dh_pub": "dh-pub"
              }
            }"#,
        );
        assert!(request.is_ok());
        let approve = parse_link_approve_request(
            br#"{
              "link_code": "link-code-123456",
              "request_id": "11111111-1111-4111-8111-111111111111",
              "approved_device_certificate": {
                "device_certificate_version": 2,
                "account_handle": "@alice:example.invalid",
                "device_id": "ios-linked",
                "device_sign_pub": "sign-pub",
                "device_dh_pub": "dh-pub",
                "issuer_kind": "device",
                "issuer_device_id": "ios-primary",
                "parent_certificate_id": "parent",
                "issued_at": "2026-02-26T12:00:00.000Z",
                "signature": "sig"
              },
              "encrypted_provisioning_blob": "ciphertext"
            }"#,
        );
        assert!(approve.is_ok());

        let complete = parse_link_complete_request(
            br#"{
              "request_id": "11111111-1111-4111-8111-111111111111",
              "poll_token": "poll-token",
              "device_pub_keys": {
                "device_id": "ios-linked",
                "dk_sign_pub": "sign-pub",
                "dk_dh_pub": "dh-pub"
              },
              "signed_prekey": {
                "prekey_id": "signed-1",
                "signed_prekey_pub": "signed-pub",
                "signature": "signed-sig"
              },
              "one_time_prekeys": [{
                "prekey_id": "one-time-1",
                "prekey_pub": "one-time-pub"
              }]
            }"#,
        );
        assert!(complete.is_ok());
        let poll = LinkPollQuery {
            poll_token: Some(" poll-token ".to_owned()),
        };
        assert_eq!(poll.poll_token.as_deref(), Some(" poll-token "));
        assert!(parse_link_start_request(b"").is_err());
        assert!(parse_link_request_create_request(b"not json").is_err());
        assert!(parse_link_approve_request(b"{}").is_err());
        assert!(parse_link_complete_request(b"not json").is_err());
    }

    #[test]
    fn push_token_requests_parse_after_session_auth_boundary() {
        let upsert = parse_push_token_upsert(
            br#"{
              "device_type": "ios",
              "token": "apns-token",
              "device_name": "",
              "push_enabled": true,
              "push_environment": "sandbox",
              "push_mode": "privacy_first",
              "token_kind": "alert"
            }"#,
        );
        assert!(upsert.is_ok());

        let update = parse_push_token_update(
            br#"{"push_enabled":false,"push_mode":"fast_notify","token_kind":"voip"}"#,
        );
        assert!(update.is_ok());
        assert!(parse_push_token_upsert(b"").is_err());
        assert!(parse_push_token_update(b"not json").is_err());
    }

    #[test]
    fn turn_credentials_request_rejects_plaintext_identifiers() {
        let request = parse_turn_credentials_request(
            br#"{
              "purpose": "call_media",
              "transport_profile": "webrtc_turn_relay",
              "capabilities": {"audio": true}
            }"#,
        );
        assert!(request.is_ok());

        let forbidden = parse_turn_credentials_request(
            br#"{
              "purpose": "call_media",
              "transport_profile": "webrtc_turn_relay",
              "call_id": "11111111-1111-4111-8111-111111111111"
            }"#,
        );
        assert!(forbidden.is_err());
    }

    #[test]
    fn public_directory_limiter_uses_fixed_window_per_key() {
        let state = HttpState::without_persistence(test_config());

        assert!(record_limited_hit(
            &state.public_directory_limits,
            Some("Client-A"),
            1_000,
            2
        ));
        assert!(record_limited_hit(
            &state.public_directory_limits,
            Some("client-a"),
            2_000,
            2
        ));
        assert!(!record_limited_hit(
            &state.public_directory_limits,
            Some("CLIENT-A"),
            3_000,
            2
        ));
        assert!(record_limited_hit(
            &state.public_directory_limits,
            Some("CLIENT-A"),
            62_000,
            2
        ));
        assert!(record_limited_hit(
            &state.public_directory_limits,
            None,
            3_000,
            0
        ));
    }

    fn sample_path(path: &str) -> String {
        path.split('/')
            .map(|segment| {
                if segment.starts_with(':') {
                    "sample-id"
                } else {
                    segment
                }
            })
            .collect::<Vec<_>>()
            .join("/")
    }

    fn insert_header(headers: &mut HeaderMap, name: &'static str, value: &'static str) {
        let parsed = HeaderValue::from_str(value);
        assert!(parsed.is_ok());
        let Ok(parsed) = parsed else {
            return;
        };
        headers.insert(name, parsed);
    }
}
