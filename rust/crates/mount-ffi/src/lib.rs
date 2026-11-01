//! A C interface to mount sessions for the Mac apps (ADR 0019): the tested
//! Celestron adapter and the controller in encoder-only mode, behind four
//! calls that take and return JSON text. See `include/cwb_mount.h`.
//!
//! Every call returns a string the caller frees with `cwb_string_free`:
//! `{"ok": true, …}` or `{"ok": false, "error": "…"}`. Sessions are numbered,
//! so the app holds no pointers into Rust. A panic is caught and reported as
//! an error rather than crossing into the app.
//!
//! This is the only crate in the workspace with `unsafe` code, and only in
//! the four C functions at the end of this file.

pub mod session;
pub mod trace;

use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

use serde_json::{Value, json};
use session::{OpenOptions, Request, Session};

fn sessions() -> &'static Mutex<HashMap<u64, Session>> {
    static SESSIONS: OnceLock<Mutex<HashMap<u64, Session>>> = OnceLock::new();
    SESSIONS.get_or_init(Mutex::default)
}

static NEXT: AtomicU64 = AtomicU64::new(1);

fn error(e: impl std::fmt::Display) -> Value {
    json!({ "ok": false, "error": e.to_string() })
}

/// Opens a session: `{"port": "/dev/cu.…" | "simulate", "safety": {…}, "celestron": {…}}`.
/// Returns `{"ok": true, "session": n, "opened": {…}}`.
pub fn open_json(options: &str) -> Value {
    let options: OpenOptions = match serde_json::from_str(options) {
        Ok(o) => o,
        Err(e) => return error(format!("options: {e}")),
    };
    match Session::open(&options) {
        Ok(session) => {
            let opened = serde_json::to_value(&session.opened).expect("serializable");
            let id = NEXT.fetch_add(1, Ordering::Relaxed);
            sessions().lock().expect("sessions").insert(id, session);
            json!({ "ok": true, "session": id, "opened": opened })
        }
        Err(e) => error(e),
    }
}

/// One request: `{"op": "arm" | "disarm" | "reset" | "stop" | "emergency_stop"}`,
/// `{"op": "reference", "altitude_deg": x}` or
/// `{"op": "goto", "axis": "azimuth", "delta_deg": x, "fast": false, "approach": "positive"}`.
pub fn command_json(session: u64, request: &str) -> Value {
    let request: Request = match serde_json::from_str(request) {
        Ok(r) => r,
        Err(e) => return error(format!("request: {e}")),
    };
    let sessions = sessions().lock().expect("sessions");
    match sessions.get(&session) {
        Some(s) => s.command(request).unwrap_or_else(error),
        None => error(format!("no session {session}")),
    }
}

/// The session's state, positions, last record and fault, and messages since the last call.
pub fn status_json(session: u64) -> Value {
    let sessions = sessions().lock().expect("sessions");
    match sessions.get(&session) {
        Some(s) => {
            let mut v = serde_json::to_value(s.status()).expect("serializable");
            v["ok"] = json!(true);
            v
        }
        None => error(format!("no session {session}")),
    }
}

/// Stops the mount and closes the session.
pub fn close(session: u64) -> Value {
    let removed = sessions().lock().expect("sessions").remove(&session);
    match removed {
        Some(s) => {
            drop(s);
            json!({ "ok": true })
        }
        None => error(format!("no session {session}")),
    }
}

fn guarded(f: impl FnOnce() -> Value) -> *mut c_char {
    let value =
        catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|_| error("internal error (panic)"));
    CString::new(value.to_string())
        .expect("JSON has no NUL bytes")
        .into_raw()
}

// --- The C boundary -----------------------------------------------------------

/// Reads a C string; null reads as empty.
///
/// # Safety
/// `s` is null or points to a NUL-terminated string valid for this call.
#[allow(unsafe_code)]
unsafe fn read(s: *const c_char) -> String {
    if s.is_null() {
        return String::new();
    }
    // SAFETY: the caller promises a valid NUL-terminated string.
    unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned()
}

/// # Safety
/// `options` is null or a NUL-terminated UTF-8 string valid for this call.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cwb_session_open(options: *const c_char) -> *mut c_char {
    // SAFETY: as documented above.
    let options = unsafe { read(options) };
    guarded(|| open_json(&options))
}

/// # Safety
/// `request` is null or a NUL-terminated UTF-8 string valid for this call.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cwb_session_command(session: u64, request: *const c_char) -> *mut c_char {
    // SAFETY: as documented above.
    let request = unsafe { read(request) };
    guarded(|| command_json(session, &request))
}

#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn cwb_session_status(session: u64) -> *mut c_char {
    guarded(|| status_json(session))
}

#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn cwb_session_close(session: u64) -> *mut c_char {
    guarded(|| close(session))
}

/// Frees a string returned by any `cwb_` call.
///
/// # Safety
/// `s` is null or a pointer returned by a `cwb_` call, not yet freed.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cwb_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: `s` came from `CString::into_raw` in `guarded`.
        drop(unsafe { CString::from_raw(s) });
    }
}
