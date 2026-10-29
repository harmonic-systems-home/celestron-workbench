//! The protocol compatibility report: Markdown for review, JSON and an
//! NDJSON trace for the record.

use std::{fmt::Write as _, fs, io, path::Path};

use crate::{
    discover::{Discovery, Status},
    proposed::{Basis, PROPOSED, RATE_NOTE, TO_OBSERVE},
    query::{LIBNEXSTAR_URL, NOT_SENT, REFERENCE, REFERENCE_URL},
};

/// Writes `report.md`, `report.json` and `trace.ndjson` into `dir`.
pub fn write(discovery: &Discovery, dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    fs::write(dir.join("report.md"), markdown(discovery))?;
    fs::write(
        dir.join("report.json"),
        serde_json::to_string_pretty(discovery)? + "\n",
    )?;
    let mut trace = String::new();
    for e in &discovery.exchanges {
        trace.push_str(&serde_json::to_string(e)?);
        trace.push('\n');
    }
    fs::write(dir.join("trace.ndjson"), trace)
}

pub fn markdown(d: &Discovery) -> String {
    let mut s = String::new();
    let w = &mut s;
    let _ = writeln!(w, "# Celestron discovery report\n");
    if d.simulated {
        let _ = writeln!(
            w,
            "> **Simulated.** These answers came from the built-in simulated hand controller, not hardware. All values are synthetic.\n"
        );
    }
    let _ = writeln!(
        w,
        "Generated {} by cwb {}. **{}**\n",
        d.generated_utc,
        d.tool_version,
        if d.ready() {
            "No failed checks: ready for operator review."
        } else {
            "Failed checks below: fix and run again."
        }
    );
    let _ = writeln!(
        w,
        "Read-only: only the {} queries in the trace were sent. No motion, goto, sync, tracking, time or location command was sent.\n",
        d.exchanges.len()
    );

    let _ = writeln!(w, "## Setup\n");
    let _ = writeln!(w, "| | |\n|---|---|");
    let op = &d.operator;
    for (k, v) in [
        ("Mount (operator)", &op.mount),
        ("Hand controller (operator)", &op.hand_controller),
        (
            "Hand controller firmware, as displayed (operator)",
            &op.hand_controller_firmware,
        ),
        ("Cable (operator)", &op.cable),
        ("Notes (operator)", &op.notes),
    ] {
        let _ = writeln!(w, "| {k} | {} |", cell(v.as_deref().unwrap_or("—")));
    }
    let _ = writeln!(w, "| Port | `{}` |", d.connection.port);
    let _ = writeln!(
        w,
        "| USB | {} |",
        d.connection
            .usb
            .as_ref()
            .map_or("—".into(), |u| cell(&u.describe()))
    );
    let _ = writeln!(w, "| Settings | {} |", d.connection.settings);
    let id = &d.identity;
    let _ = writeln!(
        w,
        "| Hand controller version (reported) | {} |",
        id.controller_version.as_deref().unwrap_or("—")
    );
    let _ = writeln!(
        w,
        "| Model (reported) | {} |",
        id.model.as_deref().unwrap_or("—")
    );
    let _ = writeln!(
        w,
        "| Motor firmware, azimuth / altitude (reported) | {} / {} |\n",
        id.motor_versions[0].as_deref().unwrap_or("—"),
        id.motor_versions[1].as_deref().unwrap_or("—")
    );

    let _ = writeln!(w, "## Checks\n");
    let _ = writeln!(w, "| Check | Result | Detail |\n|---|---|---|");
    for c in &d.checks {
        let status = match c.status {
            Status::Pass => "pass",
            Status::Warn => "**warn**",
            Status::Fail => "**FAIL**",
            Status::Info => "info",
        };
        let _ = writeln!(w, "| {} | {status} | {} |", c.name, cell(&c.detail));
    }

    let _ = writeln!(w, "\n## Trace\n");
    let _ = writeln!(
        w,
        "Every exchange, byte for byte (hex). The same data is in `trace.ndjson`.\n"
    );
    let _ = writeln!(
        w,
        "| # | Query | Sent | Received | Outcome | Value | Latency ms | Reference |\n|---|---|---|---|---|---|---|---|"
    );
    for e in &d.exchanges {
        let _ = writeln!(
            w,
            "| {} | {} | `{}` | `{}` | {:?} | {} | {:.1} | {} |",
            e.index,
            cell(&e.query),
            e.sent_hex,
            e.received_hex,
            e.outcome,
            e.value
                .as_ref()
                .map_or("—".into(), |v| cell(&v.to_string())),
            e.latency_ms,
            e.reference
        );
    }

    let _ = writeln!(
        w,
        "\n## Proposed commands for the hardware adapter (not sent)\n"
    );
    let _ = writeln!(
        w,
        "For plan Prompt 8, after this report is approved. Bytes in hex after the command letter. {RATE_NOTE}\n"
    );
    let _ = writeln!(
        w,
        "| Purpose | Bytes | Reply | Basis | Source | Notes |\n|---|---|---|---|---|---|"
    );
    for p in PROPOSED {
        let basis = match p.basis {
            Basis::Documented => "documented",
            Basis::ObservationNeeded => "**observation needed**",
        };
        let _ = writeln!(
            w,
            "| {} | `{}` | `{}` | {basis} | {} | {} |",
            p.purpose,
            p.bytes,
            p.reply,
            cell(p.source),
            cell(p.notes)
        );
    }
    let _ = writeln!(w, "\n### To observe on hardware\n");
    let _ = writeln!(
        w,
        "Not settled by any document. Established in the first hardware trials, one at a time, with the operator at the power switch:\n"
    );
    for t in TO_OBSERVE {
        let _ = writeln!(w, "- {t}");
    }

    let _ = writeln!(w, "\n## Deliberately not sent\n");
    for (what, why) in NOT_SENT {
        let _ = writeln!(w, "- {what}: {why}.");
    }

    let _ = writeln!(w, "\n## References\n");
    let _ = writeln!(
        w,
        "- {REFERENCE}, hosted by Celestron: <{REFERENCE_URL}>. Section names in the tables refer to it. It dates from 2006 and predates the Evolution, so this report's trace is the evidence that it applies to the hand controller tested."
    );
    let _ = writeln!(
        w,
        "- libnexstar (model codes after 12, including 22 = NexStar Evolution): <{LIBNEXSTAR_URL}>."
    );
    s
}

fn cell(text: &str) -> String {
    text.replace('|', "\\|").replace('\n', " ")
}
