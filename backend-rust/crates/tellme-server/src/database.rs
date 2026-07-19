//! `PostgreSQL` runtime boundary for the Rust backend.
//!
//! The migration executor reuses the existing TypeScript hard-cutover SQL files through `migrations.rs`, so the Rust
//! backend cannot silently drift into a parallel schema while endpoint adapters are added.

use crate::migrations::{pending_migrations, SCHEMA_MIGRATIONS_TABLE_SQL};
use sqlx::postgres::PgPoolOptions;
use sqlx::{Executor, PgPool};
use std::env;
use std::error::Error;
use std::fmt::{Display, Formatter};
use std::time::Duration;

const DEFAULT_DATABASE_MAX_CONNECTIONS: u32 = 10;
const DEFAULT_DATABASE_CONNECT_RETRY_ATTEMPTS: u32 = 20;
const DEFAULT_DATABASE_CONNECT_RETRY_DELAY_MS: u64 = 500;
const INSERT_MIGRATION_SQL: &str = r"
INSERT INTO schema_migrations (name)
VALUES ($1)
ON CONFLICT (name) DO NOTHING
";

/// `PostgreSQL` connection pool configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DatabaseConfig {
    database_url: String,
    max_connections: u32,
    connect_retry_attempts: u32,
    connect_retry_delay_ms: u64,
}

impl DatabaseConfig {
    /// Loads database configuration from environment variables.
    ///
    /// # Errors
    ///
    /// Returns an error when `DATABASE_URL` is missing or `DATABASE_MAX_CONNECTIONS` is invalid.
    pub fn from_env() -> Result<Self, DatabaseConfigError> {
        let database_url =
            env::var("DATABASE_URL").map_err(|_| DatabaseConfigError::MissingDatabaseUrl)?;
        let max_connections =
            read_u32_env("DATABASE_MAX_CONNECTIONS", DEFAULT_DATABASE_MAX_CONNECTIONS)?;
        let retry_attempts = read_u32_env(
            "DATABASE_CONNECT_RETRY_ATTEMPTS",
            DEFAULT_DATABASE_CONNECT_RETRY_ATTEMPTS,
        )?;
        let retry_delay_ms = read_u64_env(
            "DATABASE_CONNECT_RETRY_DELAY_MS",
            DEFAULT_DATABASE_CONNECT_RETRY_DELAY_MS,
        )?;
        Ok(Self::with_connect_retry(
            database_url,
            max_connections,
            retry_attempts,
            retry_delay_ms,
        ))
    }

    #[must_use]
    pub const fn new(database_url: String, max_connections: u32) -> Self {
        Self::with_connect_retry(
            database_url,
            max_connections,
            DEFAULT_DATABASE_CONNECT_RETRY_ATTEMPTS,
            DEFAULT_DATABASE_CONNECT_RETRY_DELAY_MS,
        )
    }

    #[must_use]
    pub const fn with_connect_retry(
        database_url: String,
        max_connections: u32,
        connect_retry_attempts: u32,
        connect_retry_delay_ms: u64,
    ) -> Self {
        Self {
            database_url,
            max_connections,
            connect_retry_attempts: if connect_retry_attempts == 0 {
                1
            } else {
                connect_retry_attempts
            },
            connect_retry_delay_ms,
        }
    }

    #[must_use]
    pub fn database_url(&self) -> &str {
        &self.database_url
    }

    #[must_use]
    pub const fn max_connections(&self) -> u32 {
        self.max_connections
    }

    #[must_use]
    pub const fn connect_retry_attempts(&self) -> u32 {
        self.connect_retry_attempts
    }

    #[must_use]
    pub const fn connect_retry_delay_ms(&self) -> u64 {
        self.connect_retry_delay_ms
    }
}

/// Database configuration error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DatabaseConfigError {
    MissingDatabaseUrl,
    InvalidNumber { name: String, value: String },
}

impl Display for DatabaseConfigError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingDatabaseUrl => formatter.write_str("DATABASE_URL is required"),
            Self::InvalidNumber { name, value } => {
                write!(formatter, "invalid numeric env {name}: {value}")
            }
        }
    }
}

impl Error for DatabaseConfigError {}

/// Database runtime error.
#[derive(Debug)]
pub enum DatabaseError {
    Sqlx(sqlx::Error),
}

impl Display for DatabaseError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Sqlx(error) => write!(formatter, "database error: {error}"),
        }
    }
}

impl Error for DatabaseError {}

impl From<sqlx::Error> for DatabaseError {
    fn from(value: sqlx::Error) -> Self {
        Self::Sqlx(value)
    }
}

/// Creates the `PostgreSQL` connection pool used by persistence adapters.
///
/// # Errors
///
/// Returns `DatabaseError` when `PostgreSQL` cannot be reached or the pool cannot be created.
pub async fn connect(config: &DatabaseConfig) -> Result<PgPool, DatabaseError> {
    let mut attempt = 1;
    loop {
        let result = connect_once(config).await;
        match result {
            Ok(pool) => return Ok(pool),
            Err(error) if attempt >= config.connect_retry_attempts() => return Err(error),
            Err(_error) => {
                attempt += 1;
                tokio::time::sleep(Duration::from_millis(config.connect_retry_delay_ms())).await;
            }
        }
    }
}

async fn connect_once(config: &DatabaseConfig) -> Result<PgPool, DatabaseError> {
    PgPoolOptions::new()
        .max_connections(config.max_connections())
        .connect(config.database_url())
        .await
        .map_err(DatabaseError::from)
}

/// Applies pending hard-cutover migrations in their TypeScript-compatible order.
///
/// # Errors
///
/// Returns `DatabaseError` when a migration query or schema migration update fails.
pub async fn apply_pending_migrations(pool: &PgPool) -> Result<Vec<&'static str>, DatabaseError> {
    pool.execute(SCHEMA_MIGRATIONS_TABLE_SQL).await?;
    let applied = applied_migration_names(pool).await?;
    let pending = pending_migrations(applied.iter().map(String::as_str));
    let mut applied_now = Vec::with_capacity(pending.len());

    for migration in pending {
        let mut transaction = pool.begin().await?;
        transaction.execute(migration.sql()).await?;
        sqlx::query(INSERT_MIGRATION_SQL)
            .bind(migration.name())
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        applied_now.push(migration.name());
    }

    Ok(applied_now)
}

/// Lists applied migration names from `PostgreSQL`.
///
/// # Errors
///
/// Returns `DatabaseError` when the schema migrations table cannot be queried.
pub async fn applied_migration_names(pool: &PgPool) -> Result<Vec<String>, DatabaseError> {
    sqlx::query_scalar::<_, String>("SELECT name FROM schema_migrations ORDER BY name ASC")
        .fetch_all(pool)
        .await
        .map_err(DatabaseError::from)
}

#[must_use]
pub const fn migration_insert_sql() -> &'static str {
    INSERT_MIGRATION_SQL
}

fn read_u32_env(name: &str, default_value: u32) -> Result<u32, DatabaseConfigError> {
    let Ok(value) = env::var(name) else {
        return Ok(default_value);
    };

    value
        .parse::<u32>()
        .map_err(|_| DatabaseConfigError::InvalidNumber {
            name: name.to_owned(),
            value,
        })
}

fn read_u64_env(name: &str, default_value: u64) -> Result<u64, DatabaseConfigError> {
    let Ok(value) = env::var(name) else {
        return Ok(default_value);
    };

    value
        .parse::<u64>()
        .map_err(|_| DatabaseConfigError::InvalidNumber {
            name: name.to_owned(),
            value,
        })
}

#[cfg(test)]
mod tests {
    use super::{
        migration_insert_sql, DatabaseConfig, DEFAULT_DATABASE_CONNECT_RETRY_ATTEMPTS,
        DEFAULT_DATABASE_CONNECT_RETRY_DELAY_MS,
    };

    #[test]
    fn database_config_keeps_runtime_values_explicit() {
        let config = DatabaseConfig::new("postgres://user:pass@host/db".to_owned(), 7);

        assert_eq!(config.database_url(), "postgres://user:pass@host/db");
        assert_eq!(config.max_connections(), 7);
        assert_eq!(
            config.connect_retry_attempts(),
            DEFAULT_DATABASE_CONNECT_RETRY_ATTEMPTS
        );
        assert_eq!(
            config.connect_retry_delay_ms(),
            DEFAULT_DATABASE_CONNECT_RETRY_DELAY_MS
        );
    }

    #[test]
    fn database_config_keeps_at_least_one_connect_attempt() {
        let config =
            DatabaseConfig::with_connect_retry("postgres://user:pass@host/db".to_owned(), 7, 0, 25);

        assert_eq!(config.connect_retry_attempts(), 1);
        assert_eq!(config.connect_retry_delay_ms(), 25);
    }

    #[test]
    fn migration_insert_sql_is_parameterized_and_idempotent() {
        let sql = migration_insert_sql();

        assert!(sql.contains("VALUES ($1)"));
        assert!(sql.contains("ON CONFLICT (name) DO NOTHING"));
        assert!(!sql.contains("{}"));
    }
}
