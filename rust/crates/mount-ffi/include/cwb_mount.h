// A C interface to mount sessions (ADR 0019); see crates/mount-ffi/src/lib.rs.
// Every call returns a JSON string that the caller frees with cwb_string_free:
// {"ok": true, ...} or {"ok": false, "error": "..."}.
#ifndef CWB_MOUNT_H
#define CWB_MOUNT_H

#include <stdint.h>

// {"port": "/dev/cu...." | "simulate", "safety": {...}, "celestron": {...}}
// -> {"ok": true, "session": n, "opened": {...}}
char *cwb_session_open(const char *options);

// {"op": "arm" | "disarm" | "reset" | "stop" | "emergency_stop"}
// {"op": "reference", "altitude_deg": x}
// {"op": "goto", "axis": "azimuth" | "altitude", "delta_deg": x, "fast": false,
//  "approach": null | "positive" | "negative"}
char *cwb_session_command(uint64_t session, const char *request);

// State, positions, altitude, last record and fault, messages since the last call.
char *cwb_session_status(uint64_t session);

// Stops the mount and closes the session.
char *cwb_session_close(uint64_t session);

void cwb_string_free(char *s);

#endif
