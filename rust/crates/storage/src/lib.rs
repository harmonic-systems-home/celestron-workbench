//! SQLite storage: connection setup and schema migrations (ADR 0003).
//!
//! Migrations are the SQL files in `schemas/sql/`, embedded at build time and
//! applied in order. `PRAGMA user_version` records how many have been applied.
//! [`ingest::Store`] writes protocol messages; [`sessions`] reads them back;
//! [`clockfit`] fits clock models from stored exchanges.

pub mod clock;
pub mod clockfit;
pub mod ingest;
pub mod sessions;

pub use clock::MacClock;
pub use ingest::{BatchOutcome, ByeOutcome, HelloOutcome, Store, StoreConfig};
pub use rusqlite::Connection;

use std::path::Path;

use rusqlite::OpenFlags;
use thiserror::Error;

/// One embedded migration. `version` is the number in the file name.
pub struct Migration {
    pub version: u32,
    pub name: &'static str,
    pub sql: &'static str,
}

/// Every migration, in order. Add new files here; never edit committed ones.
pub const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        name: "0001_initial",
        sql: include_str!("../../../../schemas/sql/0001_initial.sql"),
    },
    Migration {
        version: 2,
        name: "0002_receiver",
        sql: include_str!("../../../../schemas/sql/0002_receiver.sql"),
    },
    Migration {
        version: 3,
        name: "0003_clock_domains",
        sql: include_str!("../../../../schemas/sql/0003_clock_domains.sql"),
    },
    Migration {
        version: 4,
        name: "0004_session_sites",
        sql: include_str!("../../../../schemas/sql/0004_session_sites.sql"),
    },
];

/// The schema version a fully migrated database has.
pub const SCHEMA_VERSION: u32 = MIGRATIONS[MIGRATIONS.len() - 1].version;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("database schema version {found} is newer than this software ({supported})")]
    TooNew { found: u32, supported: u32 },
    #[error("migration {name} failed: {source}")]
    Migration {
        name: &'static str,
        source: rusqlite::Error,
    },
    #[error("unknown session or device: {0}")]
    UnknownSession(String),
    #[error("more than one session starts with {0}")]
    Ambiguous(String),
    #[error("invalid message: {0}")]
    InvalidMessage(String),
    #[error("rejected: {0}")]
    Rejected(String),
    #[error("stored data is incomplete: {0}")]
    Incomplete(String),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Opens (creating if needed) the database for writing, enables WAL and
/// foreign keys, and applies pending migrations. Also returns the versions
/// that were applied.
pub fn open(path: &Path) -> Result<(Connection, Vec<u32>), StorageError> {
    let mut conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    // Acknowledgements promise durable storage, so sync every commit.
    conn.pragma_update(None, "synchronous", "FULL")?;
    configure(&conn)?;
    let applied = migrate(&mut conn)?;
    Ok((conn, applied))
}

/// Opens an existing database read-only, e.g. for a live viewer or analysis.
pub fn open_read_only(path: &Path) -> Result<Connection, StorageError> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    configure(&conn)?;
    Ok(conn)
}

/// An in-memory, fully migrated database, for tests and simulation.
pub fn open_in_memory() -> Result<Connection, StorageError> {
    let mut conn = Connection::open_in_memory()?;
    configure(&conn)?;
    migrate(&mut conn)?;
    Ok(conn)
}

fn configure(conn: &Connection) -> Result<(), StorageError> {
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "busy_timeout", 5000)?;
    Ok(())
}

/// Returns the applied schema version (0 for an empty database).
pub fn schema_version(conn: &Connection) -> Result<u32, StorageError> {
    Ok(conn.pragma_query_value(None, "user_version", |row| row.get(0))?)
}

/// Applies every pending migration, each in its own transaction.
/// Returns the versions that were applied.
pub fn migrate(conn: &mut Connection) -> Result<Vec<u32>, StorageError> {
    let current = schema_version(conn)?;
    if current > SCHEMA_VERSION {
        return Err(StorageError::TooNew {
            found: current,
            supported: SCHEMA_VERSION,
        });
    }
    let mut applied = Vec::new();
    for migration in MIGRATIONS.iter().filter(|m| m.version > current) {
        let tx = conn.transaction()?;
        tx.execute_batch(migration.sql)
            .and_then(|()| tx.pragma_update(None, "user_version", migration.version))
            .map_err(|source| StorageError::Migration {
                name: migration.name,
                source,
            })?;
        tx.commit()?;
        applied.push(migration.version);
    }
    Ok(applied)
}

/// Checkpoints and truncates the WAL; call at the end of a session.
pub fn checkpoint(conn: &Connection) -> Result<(), StorageError> {
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    Ok(())
}
