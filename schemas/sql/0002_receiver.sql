-- Receiver bookkeeping (plan Prompt 3, ADR 0006).
-- Never edit this file after it is committed; add a new migration instead.

-- The streams the phone asked for in `hello`, as a JSON array, so an export
-- can reproduce the session's `hello` exactly.
ALTER TABLE devices ADD COLUMN streams TEXT;

-- Phone events have no ID of their own; this index makes the duplicate check
-- cheap when a session log is imported over a session received live.
CREATE INDEX session_events_by_source ON session_events (session_id, device_id, source, kind, source_ns);
