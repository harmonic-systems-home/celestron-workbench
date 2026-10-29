# ADR 0006: The phone starts and owns a recording session

**Status:** Accepted

## Context

A session needs one ID that the phone's local log, the Mac database and every report agree on. Either side could create it. At the bench the operator is standing at the phone and fixture, not at the Mac.

## Decision

- **The phone creates the session.** Tapping Start generates a random lowercase UUID `session_id`. The phone writes it into its local NDJSON log and sends it in `hello`.
- **The Mac accepts it.** On the first `hello` with an unknown `session_id`, the receiver creates the session row from the `hello` metadata. A `hello` for a known session from the same `device_id` is a reconnect; from a different `device_id` it is rejected with `device_mismatch`.
- **The phone ends the session** with `bye`. The Mac marks it ended when `bye` arrives, or leaves it `recording` and flags it `incomplete` at shutdown if `bye` never arrives.
- **Mac-side session commands** (plan Prompt 3) list, inspect, validate, export, replay and close sessions; they don't start phone recordings. Later mount sessions, where the Mac sends commands, attach to the phone's session ID.
- **Sequence numbers are assigned when a sample is accepted into the phone's acquisition buffer.** Samples dropped because the buffer is full never get one; they are counted and reported in `dropped_samples` events. A gap in sequence numbers on the Mac therefore always means transport loss, which resending can fix.
- **The NDJSON log is the phone's authoritative copy.** Every message the phone sends is written to it first. Sample batches are acknowledged and resent; markers and events sent while disconnected are queued and sent after reconnecting but are not acknowledged, so the log (imported later) is their backstop.

## Consequences

- A recording can run with no Mac at all; the log can be imported afterwards.
- The Mac must handle a session it has never seen arriving mid-way through (after a reconnect or Mac restart) by resending from the phone's log.

## Receiver behaviour (plan Prompt 3)

- **One rule for every message.** The receiver checks `protocol_version`, validates against the schema, then decodes. Anything it can't accept (bad CRC, invalid JSON, schema violation, a batch whose samples don't cover `first_seq..=last_seq`, a message before `hello` or for another session) gets an `error` and the connection is closed. Nothing from a refused message is stored. The phone reconnects and resends, as it does after any interruption.
- **Acknowledgements mean committed.** `batch_ack` carries the highest seq up to which every sample is stored, sent after the writer commits. A batch that arrives past a gap is stored, but the acknowledgement stays at the gap until it is filled.
- **Duplicates are compared, not overwritten.** A resent sample with the same stream and timestamp is skipped and counted. One with the same seq but different contents is a conflict: the stored row stays, and the conflict is recorded as an error event that `cwb session validate` reports.
- **Session status.** `bye` ends the session as `ended` if everything up to the phone's `last_seq` is stored, otherwise `incomplete`. A receiver that stops before `bye` marks its sessions `incomplete`. A later `hello` for the session sets it back to `recording`. `accepted` and `rejected` are analyst decisions and are never changed by the receiver.
- **Clock domains across restarts.** `receive_mac_ns` belongs to the receiver run named by `sessions.mac_clock_boot_id`. When a later run picks the session up, a `receiver_attached` event with `mac_clock_domain_changed: true` marks the change. A new phone `boot_id` on reconnect is recorded as `phone_clock_domain_changed`. Clock estimation (plan Prompt 4) segments on these events.
- **Import and live data merge.** `cwb session import` goes through the same code as the receiver. Samples, markers (by ID) and phone events (by kind, time and detail) that are already stored are skipped, so importing the phone's log after a live session fills in only what the network missed. Imported samples carry the import run's `receive_mac_ns`, and an `imported` event records the file's SHA-256.
