use std::error::Error;

use tellme_server::database::{
    apply_pending_migrations, connect, DatabaseConfig, DatabaseConfigError,
};
use tellme_server::session::TokenConfig;
use tellme_server::worker_scheduler::{start_worker_scheduler, WorkerSchedulerConfig};
use tellme_server::{http_router, http_router_with_pool, Config};
use tokio::sync::watch;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let config = Config::from_env()?;
    let bind_addr = config.bind_addr();
    let mut worker_scheduler = None;
    let router = match DatabaseConfig::from_env() {
        Ok(database_config) => {
            let token_config = TokenConfig::from_env()?;
            let pool = connect(&database_config).await?;
            apply_pending_migrations(&pool).await?;
            let scheduler_config = WorkerSchedulerConfig::from_env()?;
            worker_scheduler = start_worker_scheduler(pool.clone(), &scheduler_config);
            http_router_with_pool(config, pool, token_config)
        }
        Err(DatabaseConfigError::MissingDatabaseUrl) => http_router(config),
        Err(error) => return Err(Box::new(error) as Box<dyn Error>),
    };
    let listener = tokio::net::TcpListener::bind(bind_addr).await?;
    let (shutdown_tx, _shutdown_rx) = watch::channel(false);
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal(shutdown_tx.clone()))
    .await?;
    let _shutdown_sent = shutdown_tx.send(true);
    if let Some(scheduler) = worker_scheduler {
        scheduler.shutdown().await;
    }

    Ok(())
}

async fn shutdown_signal(shutdown_tx: watch::Sender<bool>) {
    let _ = tokio::signal::ctrl_c().await;
    let _shutdown_sent = shutdown_tx.send(true);
}
