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
