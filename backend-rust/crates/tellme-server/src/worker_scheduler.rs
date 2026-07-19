//! Long-lived background worker scheduler.
//!
//! The scheduler is disabled unless `TELLME_RUST_WORKERS_ENABLED=true`. When enabled, each worker starts only when its
//! runtime boundary can be configured from the existing server environment, so incomplete optional providers such as
//! APNs do not crash the HTTP server during staged Rust rollout.

use crate::federation_transport::FederationHttpTransport;
use crate::media_storage::MinioMediaObjectStore;
use crate::push_provider::{ApnsProviderConfig, ApnsPushProvider};
use crate::worker_repository::PostgresWorkerRepository;
use crate::worker_runtime::{
    run_federation_outbox_once_with_limits, run_mailbox_cleanup_once,
    run_media_cleanup_once_with_limit, run_push_once_with_provider_and_limits,
};
use crate::worker_service::WorkerError;
use crate::workers::{OUTBOX_WORKER_INTERVAL_MS, PUSH_WORKER_INTERVAL_MS, WORKER_RESERVE_LIMIT};
use sqlx::PgPool;
use std::env;
use std::future::Future;
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::sleep;

const DEFAULT_MEDIA_CLEANUP_INTERVAL_MS: u64 = 60_000;
const DEFAULT_MAILBOX_CLEANUP_INTERVAL_MS: u64 = 60_000;
const DEFAULT_WORKER_CLAIM_TTL_SEC: i64 = 300;

/// Background worker scheduler configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerSchedulerConfig {
    enabled: bool,
    outbox_interval: Duration,
    push_interval: Duration,
    mailbox_cleanup_interval: Duration,
    media_cleanup_interval: Duration,
    job_limit: i64,
    claim_ttl_sec: i64,
}

impl WorkerSchedulerConfig {
    /// Creates explicit worker scheduler configuration.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when an interval, job limit, or claim TTL is zero or negative.
    pub const fn new(
        enabled: bool,
        outbox_interval: Duration,
        push_interval: Duration,
        mailbox_cleanup_interval: Duration,
        media_cleanup_interval: Duration,
        job_limit: i64,
        claim_ttl_sec: i64,
    ) -> Result<Self, WorkerError> {
        if outbox_interval.is_zero()
            || push_interval.is_zero()
            || mailbox_cleanup_interval.is_zero()
            || media_cleanup_interval.is_zero()
            || job_limit <= 0
            || claim_ttl_sec <= 0
        {
            return Err(WorkerError);
        }

        Ok(Self {
            enabled,
            outbox_interval,
            push_interval,
            mailbox_cleanup_interval,
            media_cleanup_interval,
            job_limit,
            claim_ttl_sec,
        })
    }

    /// Builds scheduler configuration from environment variables.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when numeric environment values are invalid or non-positive.
    pub fn from_env() -> Result<Self, WorkerError> {
        let default_limit = i64::try_from(WORKER_RESERVE_LIMIT).map_err(|_| WorkerError)?;
        Self::new(
            bool_env("TELLME_RUST_WORKERS_ENABLED", false)?,
            duration_env("OUTBOX_WORKER_INTERVAL_MS", OUTBOX_WORKER_INTERVAL_MS)?,
            duration_env("PUSH_WORKER_INTERVAL_MS", PUSH_WORKER_INTERVAL_MS)?,
            duration_env(
                "MAILBOX_CLEANUP_INTERVAL_MS",
                DEFAULT_MAILBOX_CLEANUP_INTERVAL_MS,
            )?,
            duration_env(
                "MEDIA_CLEANUP_INTERVAL_MS",
                DEFAULT_MEDIA_CLEANUP_INTERVAL_MS,
            )?,
            i64_env("TELLME_RUST_WORKER_RESERVE_LIMIT", default_limit)?,
            i64_env(
                "TELLME_RUST_WORKER_CLAIM_TTL_SEC",
                DEFAULT_WORKER_CLAIM_TTL_SEC,
            )?,
        )
    }

    #[must_use]
    pub const fn enabled(&self) -> bool {
        self.enabled
    }

    #[must_use]
    pub const fn outbox_interval(&self) -> Duration {
        self.outbox_interval
    }

    #[must_use]
    pub const fn push_interval(&self) -> Duration {
        self.push_interval
    }

    #[must_use]
    pub const fn mailbox_cleanup_interval(&self) -> Duration {
        self.mailbox_cleanup_interval
    }

    #[must_use]
    pub const fn media_cleanup_interval(&self) -> Duration {
        self.media_cleanup_interval
    }

    #[must_use]
    pub const fn job_limit(&self) -> i64 {
        self.job_limit
    }

    #[must_use]
    pub const fn claim_ttl_sec(&self) -> i64 {
        self.claim_ttl_sec
    }
}

/// Running background worker supervisor.
pub struct WorkerScheduler {
    shutdown_tx: watch::Sender<bool>,
    tasks: Vec<JoinHandle<()>>,
}

impl WorkerScheduler {
    /// Requests worker shutdown and waits for all loops to finish their current tick.
    pub async fn shutdown(self) {
        let _send_result = self.shutdown_tx.send(true);
        for task in self.tasks {
            let _join_result = task.await;
        }
    }

    #[must_use]
    pub const fn task_count(&self) -> usize {
        self.tasks.len()
    }
}

/// Starts configured background workers.
#[must_use]
pub fn start_worker_scheduler(
    pool: PgPool,
    config: &WorkerSchedulerConfig,
) -> Option<WorkerScheduler> {
    if !config.enabled() {
        return None;
    }

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let repository = PostgresWorkerRepository::new(pool);
    let mut tasks = Vec::new();

    if let Ok(transport) = FederationHttpTransport::from_env() {
        tasks.push(spawn_outbox_loop(
            repository.clone(),
            transport,
            shutdown_rx.clone(),
            config.outbox_interval(),
            config.job_limit(),
            config.claim_ttl_sec(),
        ));
    }

    if let Ok(push_config) = ApnsProviderConfig::from_env() {
        tasks.push(spawn_push_loop(
            repository.clone(),
            push_config,
            shutdown_rx.clone(),
            config.push_interval(),
            config.job_limit(),
            config.claim_ttl_sec(),
        ));
    }

    tasks.push(spawn_mailbox_cleanup_loop(
        repository.clone(),
        shutdown_rx.clone(),
        config.mailbox_cleanup_interval(),
    ));

    if let Some(object_store) = MinioMediaObjectStore::from_env_optional() {
        tasks.push(spawn_media_cleanup_loop(
            repository,
            object_store,
            shutdown_rx,
            config.media_cleanup_interval(),
            config.job_limit(),
        ));
    }

    if tasks.is_empty() {
        None
    } else {
        Some(WorkerScheduler { shutdown_tx, tasks })
    }
}

fn spawn_outbox_loop(
    repository: PostgresWorkerRepository,
    transport: FederationHttpTransport,
    shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
    limit: i64,
    claim_ttl_sec: i64,
) -> JoinHandle<()> {
    spawn_worker_loop(shutdown_rx, interval, move || {
        let repository = repository.clone();
        let transport = transport.clone();
        async move {
            run_federation_outbox_once_with_limits(&repository, &transport, limit, claim_ttl_sec)
                .await
        }
    })
}

fn spawn_push_loop(
    repository: PostgresWorkerRepository,
    push_config: ApnsProviderConfig,
    shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
    limit: i64,
    claim_ttl_sec: i64,
) -> JoinHandle<()> {
    spawn_worker_loop(shutdown_rx, interval, move || {
        let repository = repository.clone();
        let push_config = push_config.clone();
        async move {
            let mut provider = ApnsPushProvider::new(push_config);
            run_push_once_with_provider_and_limits(&repository, &mut provider, limit, claim_ttl_sec)
                .await
        }
    })
}

fn spawn_mailbox_cleanup_loop(
    repository: PostgresWorkerRepository,
    shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
) -> JoinHandle<()> {
    spawn_worker_loop(shutdown_rx, interval, move || {
        let repository = repository.clone();
        async move { run_mailbox_cleanup_once(&repository).await }
    })
}

fn spawn_media_cleanup_loop(
    repository: PostgresWorkerRepository,
    object_store: MinioMediaObjectStore,
    shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
    limit: i64,
) -> JoinHandle<()> {
    spawn_worker_loop(shutdown_rx, interval, move || {
        let repository = repository.clone();
        let object_store = object_store.clone();
        async move { run_media_cleanup_once_with_limit(&repository, &object_store, limit).await }
    })
}

fn spawn_worker_loop<F, Fut>(
    mut shutdown_rx: watch::Receiver<bool>,
    interval: Duration,
    mut run_once: F,
) -> JoinHandle<()>
where
    F: FnMut() -> Fut + Send + 'static,
    Fut: Future<Output = Result<usize, WorkerError>> + Send + 'static,
{
    tokio::spawn(async move {
        let _initial_result = run_once().await;
        loop {
            tokio::select! {
                changed = shutdown_rx.changed() => {
                    if changed.is_err() || *shutdown_rx.borrow() {
                        break;
                    }
                }
                () = sleep(interval) => {
                    let _tick_result = run_once().await;
                }
            }
        }
    })
}

fn bool_env(name: &str, default: bool) -> Result<bool, WorkerError> {
    let value = env::var(name).ok().filter(|value| !value.trim().is_empty());
    bool_env_value(value.as_deref(), default)
}

fn bool_env_value(value: Option<&str>, default: bool) -> Result<bool, WorkerError> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(default);
    };
    match value.to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Ok(true),
        "0" | "false" | "no" | "off" => Ok(false),
        _ => Err(WorkerError),
    }
}

fn duration_env(name: &str, default_ms: u64) -> Result<Duration, WorkerError> {
    let value = env::var(name).ok().filter(|raw| !raw.trim().is_empty());
    duration_value(value.as_deref(), default_ms)
}

fn duration_value(value: Option<&str>, default_ms: u64) -> Result<Duration, WorkerError> {
    let value = value
        .map(str::trim)
        .filter(|raw| !raw.is_empty())
        .map(str::parse::<u64>)
        .transpose()
        .map_err(|_| WorkerError)?
        .unwrap_or(default_ms);
    if value == 0 {
        Err(WorkerError)
    } else {
        Ok(Duration::from_millis(value))
    }
}

fn i64_env(name: &str, default: i64) -> Result<i64, WorkerError> {
    let value = env::var(name).ok().filter(|raw| !raw.trim().is_empty());
    i64_value(value.as_deref(), default)
}

fn i64_value(value: Option<&str>, default: i64) -> Result<i64, WorkerError> {
    let value = value
        .map(str::trim)
        .filter(|raw| !raw.is_empty())
        .map(str::parse::<i64>)
        .transpose()
        .map_err(|_| WorkerError)?
        .unwrap_or(default);
    if value <= 0 {
        Err(WorkerError)
    } else {
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        bool_env_value, duration_value, i64_value, WorkerSchedulerConfig,
        DEFAULT_MAILBOX_CLEANUP_INTERVAL_MS, DEFAULT_MEDIA_CLEANUP_INTERVAL_MS,
        DEFAULT_WORKER_CLAIM_TTL_SEC,
    };
    use crate::workers::{OUTBOX_WORKER_INTERVAL_MS, PUSH_WORKER_INTERVAL_MS};
    use std::time::Duration;

    #[test]
    fn builds_explicit_scheduler_config() {
        let config = WorkerSchedulerConfig::new(
            true,
            Duration::from_millis(1),
            Duration::from_millis(2),
            Duration::from_millis(3),
            Duration::from_millis(4),
            5,
            6,
        );

        assert!(config.is_ok());
        let Ok(config) = config else {
            return;
        };
        assert!(config.enabled());
        assert_eq!(config.outbox_interval(), Duration::from_millis(1));
        assert_eq!(config.push_interval(), Duration::from_millis(2));
        assert_eq!(config.mailbox_cleanup_interval(), Duration::from_millis(3));
        assert_eq!(config.media_cleanup_interval(), Duration::from_millis(4));
        assert_eq!(config.job_limit(), 5);
        assert_eq!(config.claim_ttl_sec(), 6);
    }

    #[test]
    fn rejects_non_positive_scheduler_values() {
        assert!(WorkerSchedulerConfig::new(
            true,
            Duration::ZERO,
            Duration::from_millis(1),
            Duration::from_millis(1),
            Duration::from_millis(1),
            1,
            1,
        )
        .is_err());
        assert!(WorkerSchedulerConfig::new(
            true,
            Duration::from_millis(1),
            Duration::from_millis(1),
            Duration::from_millis(1),
            Duration::from_millis(1),
            0,
            1,
        )
        .is_err());
    }

    #[test]
    fn parser_defaults_match_typescript_worker_intervals() {
        assert_eq!(
            duration_value(None, OUTBOX_WORKER_INTERVAL_MS),
            Ok(Duration::from_millis(OUTBOX_WORKER_INTERVAL_MS))
        );
        assert_eq!(
            duration_value(None, PUSH_WORKER_INTERVAL_MS),
            Ok(Duration::from_millis(PUSH_WORKER_INTERVAL_MS))
        );
        assert_eq!(
            duration_value(None, DEFAULT_MEDIA_CLEANUP_INTERVAL_MS),
            Ok(Duration::from_millis(DEFAULT_MEDIA_CLEANUP_INTERVAL_MS))
        );
        assert_eq!(
            duration_value(None, DEFAULT_MAILBOX_CLEANUP_INTERVAL_MS),
            Ok(Duration::from_millis(DEFAULT_MAILBOX_CLEANUP_INTERVAL_MS))
        );
        assert_eq!(
            i64_value(None, DEFAULT_WORKER_CLAIM_TTL_SEC),
            Ok(DEFAULT_WORKER_CLAIM_TTL_SEC)
        );
    }

    #[test]
    fn parser_rejects_bad_values() {
        assert_eq!(bool_env_value(Some("true"), false), Ok(true));
        assert_eq!(bool_env_value(Some("off"), true), Ok(false));
        assert_eq!(
            bool_env_value(Some("sometimes"), false),
            Err(super::WorkerError)
        );
        assert_eq!(duration_value(Some("0"), 1), Err(super::WorkerError));
        assert_eq!(duration_value(Some("bad"), 1), Err(super::WorkerError));
        assert_eq!(i64_value(Some("-1"), 1), Err(super::WorkerError));
    }
}
