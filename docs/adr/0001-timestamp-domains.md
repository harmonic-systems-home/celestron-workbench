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

## Clock exchange and fit (plan Prompt 4)

Kept basic on purpose: step-and-settle tests only need tens of milliseconds (ADR 0007).

- **Exchange.** While connected the phone sends `clock_ping` (its send time), 1 s apart for the first five after each connect, then every 5 s. The receiver answers at once with `clock_pong`, adding its receive time (taken when the socket read returned, so a ping waiting behind a database commit is not stamped late) and its send time. The phone stamps the pong on arrival and sends `clock_result` with all four times. Results are logged on the phone first, like markers, and imported with the log.
- **Mac clock domain on every exchange.** `clock_pong` and `clock_result` carry `mac_clock_boot_id`, the receiver run that answered. An imported phone log can therefore hold exchanges from several receiver runs without ambiguity. Exchanges are stored raw in `clock_sync` and compared on re-import: a different exchange with the same index is refused.
- **Fit (`min_rtt_linear_v2`).** One model per device and receiver run. Each exchange gives a round trip, `(t4 − t1) − (t3 − t2)`, and an offset, `((t2 − t1) + (t3 − t4)) / 2`, at its phone midpoint. Delay only ever adds, so exchanges with round trips above the median are dropped, and so are any more than 250 ms slower than the fastest. (v1 had only the median cut, which fails when most exchanges are delayed: pings queued behind a backlog resent after a reconnect, docs/observations.md O6.) A least-squares line through the rest gives offset and drift; drift is fitted only over at least 30 s and 3 exchanges, otherwise it is zero.
- **Uncertainty** is half the longest kept round trip (each exchange's bound on an undetectable constant asymmetry between the two directions is half its round trip, and the fit averages them all), plus twice the RMS residual. `ClockModel::resolves` is the check analysis uses before claiming a cross-domain interval.
- **Models are derived.** `cwb session validate` shows a fresh fit; `cwb session clock --save` stores one in `clock_models`, keeping earlier versions. Aligned times in `sample_alignment` are not written yet; nothing needs them before bench analysis.
- **Not done:** plots of round trip and residuals, robust fitting beyond the median cut, and segmenting on a phone reboot within a session (the phone starts a new session after relaunching, so this has not arisen).
