//! Executable Rust-port coverage checklist for the frozen iOS client/server contract.

/// Rust port status for one HTTP endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// Port readiness stays explicit so route cutovers do not infer success from process health alone.
pub enum RustPortStatus {
    ServiceBoundary,
    ProtocolOnly,
    PendingHttpPersistence,
}

/// One frozen route contract entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RouteContract {
    pub method: &'static str,
    pub path: &'static str,
    pub client_required: bool,
    pub status: RustPortStatus,
}

/// Current iOS-required and protocol-required route coverage.
pub const ROUTES: &[RouteContract] = &[
    client(
        "POST",
        "/api/auth/register",
        RustPortStatus::ServiceBoundary,
    ),
    client("POST", "/api/auth/start", RustPortStatus::ServiceBoundary),
    client("POST", "/api/auth/finish", RustPortStatus::ServiceBoundary),
    client("POST", "/api/auth/refresh", RustPortStatus::ServiceBoundary),
    client("POST", "/api/auth/logout", RustPortStatus::ServiceBoundary),
    client(
        "POST",
        "/api/prekeys/publish",
        RustPortStatus::ServiceBoundary,
    ),
    client("GET", "/api/prekeys/get", RustPortStatus::ServiceBoundary),
    client("GET", "/api/prekeys/self", RustPortStatus::ServiceBoundary),
    client(
        "POST",
        "/api/messages/send",
        RustPortStatus::ServiceBoundary,
    ),
    client("POST", "/api/messages/ack", RustPortStatus::ServiceBoundary),
    client(
        "POST",
        "/api/turn/credentials",
        RustPortStatus::ServiceBoundary,
    ),
    client("GET", "/api/sync/stream", RustPortStatus::ServiceBoundary),
    client(
        "POST",
        "/api/media/upload/init",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "PUT",
        "/api/media/upload/:id",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "GET",
        "/api/media/ciphertext/:id",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "POST",
        "/api/devices/register",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "POST",
        "/api/devices/revoke",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "POST",
        "/api/devices/link/start",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "POST",
        "/api/devices/link/request",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "GET",
        "/api/devices/link/session/:sessionId/requests",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "GET",
        "/api/devices/link/request/:requestId",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "POST",
        "/api/devices/link/approve",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "POST",
        "/api/devices/link/complete",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "POST",
        "/api/devices/push/tokens",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "GET",
        "/api/devices/push/tokens",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "PUT",
        "/api/devices/push/tokens/:token",
        RustPortStatus::ServiceBoundary,
    ),
    client(
        "DELETE",
        "/api/devices/push/tokens/:token",
        RustPortStatus::ServiceBoundary,
    ),
    protocol(
        "GET",
        "/federation/v1/server-keys",
        RustPortStatus::ServiceBoundary,
    ),
    protocol(
        "GET",
        "/federation/v1/prekeys/:userHandle",
        RustPortStatus::ServiceBoundary,
    ),
    protocol(
        "POST",
        "/federation/v1/deliver",
        RustPortStatus::ServiceBoundary,
    ),
    protocol(
        "POST",
        "/federation/v1/receipts",
        RustPortStatus::ServiceBoundary,
    ),
];

#[must_use]
pub fn client_required_count() -> usize {
    ROUTES.iter().filter(|route| route.client_required).count()
}

#[must_use]
pub fn service_boundary_count() -> usize {
    ROUTES
        .iter()
        .filter(|route| matches!(route.status, RustPortStatus::ServiceBoundary))
        .count()
}

#[must_use]
pub fn has_route(method: &str, path: &str) -> bool {
    ROUTES
        .iter()
        .any(|route| route.method == method && route.path == path)
}

const fn client(method: &'static str, path: &'static str, status: RustPortStatus) -> RouteContract {
    RouteContract {
        method,
        path,
        client_required: true,
        status,
    }
}

const fn protocol(
    method: &'static str,
    path: &'static str,
    status: RustPortStatus,
) -> RouteContract {
    RouteContract {
        method,
        path,
        client_required: false,
        status,
    }
}

#[cfg(test)]
mod tests {
    use super::{client_required_count, has_route, service_boundary_count, ROUTES};

    #[test]
    fn tracks_all_current_ios_required_routes() {
        assert_eq!(client_required_count(), 27);
        assert!(has_route("POST", "/api/auth/register"));
        assert!(has_route("POST", "/api/turn/credentials"));
        assert!(has_route("POST", "/api/devices/link/complete"));
        assert!(has_route("GET", "/api/media/ciphertext/:id"));
    }

    #[test]
    fn keeps_legacy_plaintext_call_routes_out_of_rust_contract() {
        assert!(!ROUTES.iter().any(|route| route.path.contains("/calls")));
        assert!(!ROUTES.iter().any(|route| route.path.contains("call_offer")));
    }

    #[test]
    fn records_current_service_boundary_progress() {
        assert_eq!(service_boundary_count(), 31);
    }
}
