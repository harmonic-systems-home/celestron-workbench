# ADR 0004: Framed JSON over TCP on local Wi-Fi

**Status:** Accepted

## Context

Core Motion data can't be streamed over the Lightning/USB-C cable as a serial device; USB networking and accessory protocols bring entitlement and hardware constraints. Local Wi-Fi with Network.framework on the phone is the direct route.

## Decision

- **Transport:** TCP on the local network. The phone connects to the Mac's receiver. The Mac's address is entered or discovered via Bonjour (`_cwb-imu._tcp`). Addresses are local config and are never committed.
- **Framing:** every message is one frame:

  ```text
  +----------------+----------------------+----------------+
  | length: u32 BE | payload: UTF-8 JSON  | crc32: u32 BE  |
  +----------------+----------------------+----------------+
  ```

  `length` counts payload bytes only. `crc32` is CRC-32/ISO-HDLC (the zlib/PNG CRC) of the payload. A frame with a bad CRC or a length above the maximum (1 MiB) closes the connection; the phone reconnects and resends.

  The plan asked for a checksum inside each batch. A frame-level CRC covers every message type and avoids depending on identical JSON serialization in Swift and Rust, so the checksum lives here instead.
- **Payload:** JSON, one object per frame, discriminated by a `type` field, defined by the JSON Schemas in `schemas/protocol/`. JSON is fine for the bench build; switch to CBOR or MessagePack only after profiling shows a need.
- **Versioning:** every message carries `protocol_version` (integer, currently `1`). The receiver rejects versions it doesn't know, with an `error` message.
- **Reliability:** sample batches carry a contiguous `first_seq..last_seq` range. The receiver acknowledges the highest contiguous sequence number it has durably stored. On reconnect, `hello_ack` returns that number and the phone resends everything after it from its local NDJSON fallback. Duplicates are detected by `(session, device, seq)` and ignored.
- **Trust:** single operator on a trusted network. The Mac accepts one phone per session, identified by `device_id` (a random UUID the app generates once; not `identifierForVendor`). There is no encryption in v1. If the network is not trusted, this must change before use; recorded in [assumptions](../assumptions.md).

## Consequences

- The phone must keep a local NDJSON fallback for at least as long as it may be disconnected.
- Swift and Rust implement the same framing. Shared example messages in `schemas/protocol/examples/` are decoded by both test suites.
