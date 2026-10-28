# ADR 0001: Timestamps stay in their own clock domains

**Status:** Accepted

## Context

Two machines produce events: the iPhone (motion samples) and the Mac (mount commands, mount responses, operator actions). Their clocks have different epochs, rates and failure modes. Wall-clock time can jump (NTP, time zones, manual changes) and must not be used to order samples.

## Decision

- **Store each timestamp as signed 64-bit integer nanoseconds in the clock domain that produced it.** Column and field names carry the domain:
  - `*_phone_ns` / `t_ns` on the wire: iPhone monotonic time. For Core Motion samples this is `CMLogItem.timestamp` (seconds since boot) converted to integer nanoseconds. App-generated events use the same clock (`ProcessInfo.systemUptime`).
  - `*_mac_ns`: Mac monotonic time from the receiver process. In Rust this is a fixed `Instant` anchor taken at process start, plus a `clock_boot_id` recorded per session so values from different process runs are never compared.
  - `*_utc`: wall-clock UTC as an ISO 8601 string. Used only for humans and for labelling sessions, never for ordering or arithmetic.
- **Never imply that phone and Mac clocks share an epoch.** Converting a phone time to Mac time produces a *derived* value (`aligned_ns`). It always carries the ID of the clock model that produced it and an uncertainty in nanoseconds.
- **Clock models come from a four-timestamp exchange** (phone send, Mac receive, Mac send, phone receive), repeated throughout a session. The fit (offset and drift, piecewise across discontinuities) is a later milestone (plan Prompt 4). Every exchange is stored raw so models can be refitted.
- **Ordering:** phone samples are ordered by `seq` (assigned at acquisition) and then `t_ns`. Mac events are ordered by `*_mac_ns`. Cross-domain ordering is only claimed when the gap between two events exceeds the clock uncertainty.

## Consequences

- Every latency claim must be checked against clock uncertainty; analysis refuses claims finer than it.
- A reboot of either device starts a new clock domain. The phone reports its boot session in `hello`; a change mid-session ends that segment.
- `CMLogItem.timestamp` is believed to pause during device sleep (it is based on uptime). Sessions require the app to stay in the foreground with the screen on, which avoids the question. Listed in [assumptions](../assumptions.md).
