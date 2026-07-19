//! `PostgreSQL` migration and schema contract for the `TellMe` hard-cutover backend.
//!
//! The Rust backend intentionally uses the existing SQL files as the schema source of truth while domains are ported
//! incrementally. This keeps the Rust rewrite compatible with the production TypeScript backend instead of creating a
//! parallel schema.

use std::collections::BTreeSet;

/// SQL used to track applied migrations.
pub const SCHEMA_MIGRATIONS_TABLE_SQL: &str = r"
CREATE TABLE IF NOT EXISTS schema_migrations (
  name VARCHAR(255) PRIMARY KEY,
  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
";

/// One ordered SQL migration from the hard-cutover schema.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Migration {
    name: &'static str,
    sql: &'static str,
}

impl Migration {
    #[must_use]
    pub const fn new(name: &'static str, sql: &'static str) -> Self {
        Self { name, sql }
    }

    #[must_use]
    pub const fn name(self) -> &'static str {
        self.name
    }

    #[must_use]
    pub const fn sql(self) -> &'static str {
        self.sql
    }
}

/// Required table/column contract consumed by current iOS and federation flows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SchemaTable {
    name: &'static str,
    required_columns: &'static [&'static str],
}

impl SchemaTable {
    #[must_use]
    pub const fn new(name: &'static str, required_columns: &'static [&'static str]) -> Self {
        Self {
            name,
            required_columns,
        }
    }

    #[must_use]
    pub const fn name(self) -> &'static str {
        self.name
    }

    #[must_use]
    pub const fn required_columns(self) -> &'static [&'static str] {
        self.required_columns
    }
}

const MIGRATION_01: &str = include_str!("../../../../docker/init-scripts/01-init-schema.sql");
const MIGRATION_02: &str = include_str!("../../../../docker/init-scripts/02-phase3-messaging.sql");
const MIGRATION_03: &str = include_str!("../../../../docker/init-scripts/03-phase4-mesh.sql");
const MIGRATION_04: &str = include_str!("../../../../docker/init-scripts/04-phase5-calling.sql");
const MIGRATION_05: &str =
    include_str!("../../../../docker/init-scripts/05-phase6-optimization.sql");
const MIGRATION_06: &str = include_str!("../../../../docker/init-scripts/06-phase7-e2e-trust.sql");
const MIGRATION_07: &str =
    include_str!("../../../../docker/init-scripts/07-phase8-federated-e2e.sql");
const MIGRATION_08: &str =
    include_str!("../../../../docker/init-scripts/08-phase8-device-push-tokens.sql");
const MIGRATION_09: &str =
    include_str!("../../../../docker/init-scripts/09-phase9-drop-legacy-schema.sql");
const MIGRATION_10: &str = include_str!("../../../../docker/init-scripts/10-phase10-push-jobs.sql");
const MIGRATION_11: &str =
    include_str!("../../../../docker/init-scripts/11-phase11-job-claims.sql");
const MIGRATION_12: &str =
    include_str!("../../../../docker/init-scripts/12-phase12-push-sender-visible-chat.sql");
const MIGRATION_13: &str =
    include_str!("../../../../docker/init-scripts/13-phase13-secure-media.sql");
const MIGRATION_14: &str =
    include_str!("../../../../docker/init-scripts/14-phase14-device-link-completion.sql");
const MIGRATION_15: &str =
    include_str!("../../../../docker/init-scripts/15-phase15-push-token-global-uniqueness.sql");
const MIGRATION_16: &str =
    include_str!("../../../../docker/init-scripts/16-phase16-protocol-v2-cutover.sql");
const MIGRATION_17: &str =
    include_str!("../../../../docker/init-scripts/17-phase17-calls-turn-relay-only.sql");

/// Ordered migration list. This must match `src/database/migrate.ts`.
// Keep this list ordered to match the production schema bootstrap sequence.
pub const MIGRATIONS: &[Migration] = &[
    Migration::new("01-init-schema.sql", MIGRATION_01),
    Migration::new("02-phase3-messaging.sql", MIGRATION_02),
    Migration::new("03-phase4-mesh.sql", MIGRATION_03),
    Migration::new("04-phase5-calling.sql", MIGRATION_04),
    Migration::new("05-phase6-optimization.sql", MIGRATION_05),
    Migration::new("06-phase7-e2e-trust.sql", MIGRATION_06),
    Migration::new("07-phase8-federated-e2e.sql", MIGRATION_07),
    Migration::new("08-phase8-device-push-tokens.sql", MIGRATION_08),
    Migration::new("09-phase9-drop-legacy-schema.sql", MIGRATION_09),
    Migration::new("10-phase10-push-jobs.sql", MIGRATION_10),
    Migration::new("11-phase11-job-claims.sql", MIGRATION_11),
    Migration::new("12-phase12-push-sender-visible-chat.sql", MIGRATION_12),
    Migration::new("13-phase13-secure-media.sql", MIGRATION_13),
    Migration::new("14-phase14-device-link-completion.sql", MIGRATION_14),
    Migration::new("15-phase15-push-token-global-uniqueness.sql", MIGRATION_15),
    Migration::new("16-phase16-protocol-v2-cutover.sql", MIGRATION_16),
    Migration::new("17-phase17-calls-turn-relay-only.sql", MIGRATION_17),
];

/// Current hard-cutover schema needed before Rust auth/devices/prekeys/messages are enabled.
pub const REQUIRED_SCHEMA: &[SchemaTable] = &[
    SchemaTable::new(
        "accounts",
        &[
            "id",
            "user_handle",
            "home_server",
            "created_at",
            "updated_at",
        ],
    ),
    SchemaTable::new(
        "account_settings",
        &["account_id", "allow_search", "allow_requests"],
    ),
    SchemaTable::new(
        "identity_keys",
        &[
            "account_id",
            "ik_sign_pub",
            "ik_dh_pub",
            "proof_signature",
            "proof_timestamp",
        ],
    ),
    SchemaTable::new(
        "devices",
        &[
            "account_id",
            "device_id",
            "dk_sign_pub",
            "dk_dh_pub",
            "ik_device_signature",
            "device_certificate_version",
            "device_certificate_chain",
            "state",
        ],
    ),
    SchemaTable::new(
        "signed_prekeys",
        &[
            "account_id",
            "device_id",
            "prekey_id",
            "signed_prekey_pub",
            "signature",
        ],
    ),
    SchemaTable::new(
        "one_time_prekeys",
        &[
            "account_id",
            "device_id",
            "prekey_id",
            "prekey_pub",
            "consumed_at",
        ],
    ),
    SchemaTable::new(
        "auth_challenges",
        &[
            "challenge_id",
            "account_id",
            "device_id",
            "nonce",
            "expires_at",
            "used_at",
        ],
    ),
    SchemaTable::new(
        "sessions",
        &[
            "session_id",
            "account_id",
            "device_id",
            "token_hash",
            "expires_at",
            "revoked_at",
        ],
    ),
    SchemaTable::new(
        "refresh_sessions",
        &[
            "refresh_id",
            "account_id",
            "device_id",
            "token_hash",
            "expires_at",
            "revoked_at",
            "replaced_by_hash",
        ],
    ),
    SchemaTable::new(
        "mailbox_blobs",
        &[
            "owner_account_id",
            "owner_device_id",
            "sender_server",
            "message_id",
            "delivery_id",
            "ciphertext_blob",
            "envelope",
            "ttl_sec",
            "expires_at",
            "acked_at",
        ],
    ),
    SchemaTable::new(
        "outbox_jobs",
        &[
            "to_server",
            "payload",
            "status",
            "attempts",
            "next_attempt_at",
            "claimed_at",
            "claim_token",
        ],
    ),
    SchemaTable::new(
        "federation_servers",
        &[
            "domain",
            "key_id",
            "server_sign_pub",
            "trust_state",
            "metadata",
            "last_seen_at",
        ],
    ),
    SchemaTable::new(
        "federation_receipts",
        &[
            "from_server",
            "message_id",
            "delivery_id",
            "status",
            "detail",
        ],
    ),
    SchemaTable::new(
        "device_link_sessions",
        &[
            "account_id",
            "old_device_id",
            "link_code_hash",
            "l_dh_pub",
            "expires_at",
            "approved_at",
        ],
    ),
    SchemaTable::new(
        "device_link_requests",
        &[
            "session_id",
            "user_handle",
            "new_device_id",
            "n_dh_pub",
            "dk_sign_pub",
            "dk_dh_pub",
            "approved_device_certificate",
            "encrypted_provisioning_blob",
            "poll_token_hash",
            "completed_at",
            "status",
        ],
    ),
    SchemaTable::new(
        "media_objects",
        &[
            "owner_account_id",
            "mime_hint",
            "size_hint",
            "storage_bucket",
            "storage_key",
            "hash_ciphertext",
            "download_capability_hash",
            "origin_server",
            "signer_device_id",
            "attestation_signature",
            "ciphertext_size",
            "scan_verdict",
            "risk_flags",
            "status",
        ],
    ),
    SchemaTable::new(
        "device_push_tokens",
        &[
            "account_id",
            "device_id",
            "device_type",
            "token",
            "push_environment",
            "push_mode",
            "token_kind",
            "push_enabled",
            "last_used_at",
        ],
    ),
    SchemaTable::new(
        "push_jobs",
        &[
            "owner_account_id",
            "owner_device_id",
            "from_device_id",
            "message_id",
            "delivery_id",
            "dedupe_key",
            "push_kind",
            "wakeup_class",
            "status",
            "claimed_at",
            "claim_token",
        ],
    ),
];

#[must_use]
pub const fn migrations() -> &'static [Migration] {
    MIGRATIONS
}

#[must_use]
pub const fn required_schema() -> &'static [SchemaTable] {
    REQUIRED_SCHEMA
}

#[must_use]
pub fn migration_names() -> Vec<&'static str> {
    MIGRATIONS
        .iter()
        .copied()
        .map(Migration::name)
        .collect::<Vec<_>>()
}

#[must_use]
pub fn migration_by_name(name: &str) -> Option<Migration> {
    MIGRATIONS
        .iter()
        .copied()
        .find(|migration| migration.name() == name)
}

#[must_use]
pub fn pending_migrations<'a>(applied_names: impl IntoIterator<Item = &'a str>) -> Vec<Migration> {
    let applied = applied_names.into_iter().collect::<BTreeSet<_>>();
    MIGRATIONS
        .iter()
        .copied()
        .filter(|migration| !applied.contains(migration.name()))
        .collect::<Vec<_>>()
}

#[must_use]
pub fn combined_migration_sql() -> String {
    let mut combined = String::new();
    for migration in MIGRATIONS {
        combined.push_str(migration.sql());
        combined.push('\n');
    }
    combined
}

#[cfg(test)]
mod tests {
    use super::{
        combined_migration_sql, migration_by_name, migration_names, pending_migrations,
        required_schema, Migration, SCHEMA_MIGRATIONS_TABLE_SQL,
    };

    #[test]
    fn migration_order_matches_typescript_runner() {
        assert_eq!(
            migration_names(),
            vec![
                "01-init-schema.sql",
                "02-phase3-messaging.sql",
                "03-phase4-mesh.sql",
                "04-phase5-calling.sql",
                "05-phase6-optimization.sql",
                "06-phase7-e2e-trust.sql",
                "07-phase8-federated-e2e.sql",
                "08-phase8-device-push-tokens.sql",
                "09-phase9-drop-legacy-schema.sql",
                "10-phase10-push-jobs.sql",
                "11-phase11-job-claims.sql",
                "12-phase12-push-sender-visible-chat.sql",
                "13-phase13-secure-media.sql",
                "14-phase14-device-link-completion.sql",
                "15-phase15-push-token-global-uniqueness.sql",
                "16-phase16-protocol-v2-cutover.sql",
                "17-phase17-calls-turn-relay-only.sql",
            ]
        );
    }

    #[test]
    fn pre_federation_migrations_are_retired_noops() {
        for name in [
            "01-init-schema.sql",
            "02-phase3-messaging.sql",
            "03-phase4-mesh.sql",
            "04-phase5-calling.sql",
            "05-phase6-optimization.sql",
            "06-phase7-e2e-trust.sql",
        ] {
            let migration = migration_by_name(name);
            assert!(migration.is_some(), "missing migration {name}");
            if let Some(existing) = migration {
                assert!(existing.sql().contains("Retired in hard-cutover"));
                assert!(!existing.sql().contains("CREATE TABLE"));
                assert!(!existing.sql().contains("ALTER TABLE"));
                assert!(!existing.sql().contains("DROP TABLE"));
            }
        }
    }

    #[test]
    fn pending_migration_plan_preserves_order() {
        let pending = pending_migrations([
            "01-init-schema.sql",
            "02-phase3-messaging.sql",
            "03-phase4-mesh.sql",
        ]);

        assert_eq!(
            pending.first().copied().map(Migration::name),
            Some("04-phase5-calling.sql")
        );
        assert_eq!(
            pending.last().copied().map(Migration::name),
            Some("17-phase17-calls-turn-relay-only.sql")
        );
    }

    #[test]
    fn schema_contract_columns_are_declared_by_migrations() {
        let combined = combined_migration_sql();
        for table in required_schema() {
            assert!(
                combined.contains(table.name()),
                "missing table {}",
                table.name()
            );
            for column in table.required_columns() {
                assert!(
                    combined.contains(column),
                    "missing column {}.{}",
                    table.name(),
                    column
                );
            }
        }
    }

    #[test]
    fn phase_16_removes_plaintext_push_hints_and_flushes_precutover_state() {
        let phase_16 = migration_by_name("16-phase16-protocol-v2-cutover.sql");
        assert!(phase_16.is_some(), "missing phase 16 migration");
        if let Some(migration) = phase_16 {
            assert!(migration.sql().contains("DROP COLUMN sender_user_handle"));
            assert!(migration.sql().contains("DROP COLUMN notification_hint"));
            assert!(migration
                .sql()
                .contains("ADD COLUMN IF NOT EXISTS push_kind"));
            assert!(migration.sql().contains("DELETE FROM sessions;"));
            assert!(migration.sql().contains("DELETE FROM mailbox_blobs;"));
            assert!(migration.sql().contains("DELETE FROM push_jobs;"));
        }
    }

    #[test]
    fn phase_17_adds_opaque_call_wake_routing_only() {
        let phase_17 = migration_by_name("17-phase17-calls-turn-relay-only.sql");
        assert!(phase_17.is_some(), "missing phase 17 migration");
        if let Some(migration) = phase_17 {
            assert!(migration
                .sql()
                .contains("ADD COLUMN IF NOT EXISTS token_kind"));
            assert!(migration
                .sql()
                .contains("ADD COLUMN IF NOT EXISTS wakeup_class"));
            assert!(migration.sql().contains("'voip_opaque'"));
            assert!(!migration.sql().contains("call_id"));
            assert!(!migration.sql().contains("conversation_id"));
        }
    }

    #[test]
    fn schema_migrations_table_matches_typescript_runner_contract() {
        assert!(SCHEMA_MIGRATIONS_TABLE_SQL.contains("schema_migrations"));
        assert!(SCHEMA_MIGRATIONS_TABLE_SQL.contains("name VARCHAR(255) PRIMARY KEY"));
        assert!(
            SCHEMA_MIGRATIONS_TABLE_SQL.contains("applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP")
        );
    }

    #[test]
    fn unknown_migration_names_are_rejected() {
        assert_eq!(migration_by_name("00-unknown.sql"), None);
    }
}
