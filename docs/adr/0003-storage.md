# ADR 0003: SQLite via rusqlite, single writer, append-only raw data

**Status:** Accepted

## Decision

- **One SQLite database per data directory.** It holds all sessions, so queries can compare across them. The database lives in the private data location (see [privacy](../privacy.md)), never in this repo.
- **rusqlite** with the bundled SQLite build, so every machine runs the same SQLite version. SQLx was considered; its async API adds little because the plan already calls for a single writer task, and rusqlite keeps migrations and tests synchronous and simple.
- **Migrations** are plain SQL files in `schemas/sql/`, numbered `NNNN_name.sql`, applied in order inside a transaction. `PRAGMA user_version` records the applied version. Migrations are never edited after they are committed; fixes go in a new migration.
- **Single writer.** One task owns the write connection; producers send to it over bounded channels, so overload shows up as back-pressure and counted drops instead of lock contention. Readers open separate read-only connections.
- **WAL mode** is enabled for concurrent live viewing, with a `PRAGMA wal_checkpoint(TRUNCATE)` at session end. Benchmark before relying on it under load. The write connection uses `synchronous = FULL`, because the receiver acknowledges samples as durably stored.
- **Raw tables are append-only**: `sensor_samples`, `clock_sync`, `mount_events`, `markers`. Triggers reject `UPDATE` and `DELETE` on them. Corrections, smoothing, frame changes and resampling go into derived tables with provenance.
- **Unavailable values are `NULL`.** Missing samples are never filled in by interpolation in raw tables.
- **NDJSON export** is the immutable, inspectable copy of a session, hashed with SHA-256 and listed in the session manifest.

## Consequences

- Deleting a session means deleting the database file or a deliberate admin tool that drops the triggers; normal code can't do it by accident.
- Schema changes need a new migration and a test that applies every migration from empty.
