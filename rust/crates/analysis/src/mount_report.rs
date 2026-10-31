//! Report files for a [`MountAnalysis`] (ADR 0017): Markdown and HTML with the
//! same content, JSON metrics, CSV tables and SVG graphs. Output depends only
//! on the analysis, so the same logs and config give byte-identical files.

use std::fmt::Write as _;

use crate::{
    mount::{Axis, Estimate, Group, History, Kind, MountAnalysis, Move},
    report::{
        Axis as PlotAxis, BOTTOM, Block, COLORS, H, LEFT, RIGHT, TOP, W, escape, html, markdown,
        tick,
    },
};

/// A group appears in the report's tables and graphs with at least this many
/// repeats and reversals; every group is in `groups.csv`.
const MIN_SIDE: usize = 2;

pub fn render(a: &MountAnalysis) -> Vec<(String, String)> {
    let mut files = Vec::new();
    let mut images = Vec::new();
    for axis in [Axis::Azimuth, Axis::Altitude] {
        if let Some(svg) = sweep_svg(a, axis, Measure::OverCorrection) {
            let name = format!("over_correction_{}.svg", axis.name());
            images.push((axis, Measure::OverCorrection, name.clone()));
            files.push((name, svg));
        }
        if let Some(svg) = sweep_svg(a, axis, Measure::Takeup) {
            let name = format!("takeup_{}.svg", axis.name());
            images.push((axis, Measure::Takeup, name.clone()));
            files.push((name, svg));
        }
        if let Some(svg) = spread_svg(a, axis) {
            let name = format!("moves_{}.svg", axis.name());
            images.push((axis, Measure::Spread, name.clone()));
            files.push((name, svg));
        }
    }
    let speeds = (!a.speeds.is_empty()).then(|| speeds_svg(a));
    if let Some(svg) = &speeds {
        files.push(("keypad_speeds.svg".into(), svg.clone()));
    }
    let latency =
        (!a.latencies_ms.is_empty() || !a.read_gaps_ms.is_empty()).then(|| latency_svg(a));
    if let Some(svg) = &latency {
        files.push(("latency.svg".into(), svg.clone()));
    }
    if let Some(svg) = performance_svg(a) {
        files.push(("performance.svg".into(), svg));
    }
    let doc = document(a, &images, speeds.is_some(), latency.is_some());
    let title = title(a);
    let mut out = vec![
        ("report.md".to_string(), markdown(&doc)),
        ("report.html".to_string(), html(&doc, &title)),
        (
            "metrics.json".to_string(),
            serde_json::to_string_pretty(a).expect("serializable") + "\n",
        ),
        ("moves.csv".to_string(), moves_csv(a)),
        ("groups.csv".to_string(), groups_csv(a)),
    ];
    out.extend(files);
    out
}

fn title(a: &MountAnalysis) -> String {
    let hw: Vec<&str> = a
        .runs
        .iter()
        .filter(|r| r.hardware != Some(false))
        .map(|r| r.name.as_str())
        .collect();
    match (hw.first(), hw.last()) {
        (Some(first), Some(last)) if first != last => {
            format!("Mount report: {} runs, {first} to {last}", hw.len())
        }
        (Some(first), _) => format!("Mount report: run {first}"),
        _ => "Mount report: no hardware runs".into(),
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Measure {
    OverCorrection,
    Takeup,
    Spread,
}

fn shown(g: &Group) -> bool {
    g.repeats.as_ref().is_some_and(|s| s.n >= MIN_SIDE)
        && g.reversals.as_ref().is_some_and(|s| s.n >= MIN_SIDE)
}

fn document(
    a: &MountAnalysis,
    images: &[(Axis, Measure, String)],
    speeds: bool,
    latency: bool,
) -> Vec<Block> {
    use Block::*;
    let mut d = vec![Heading(1, title(a))];
    let hw: Vec<_> = a
        .runs
        .iter()
        .filter(|r| r.hardware != Some(false))
        .collect();

    d.push(Heading(2, "Method and runs".into()));
    d.push(List(vec![
        format!(
            "Method `{}`, config `{}` (SHA-256 `{}`), software {}. {} hardware run(s) from {} to {}; {} move(s), {} counted (first moves of a run, faulted and disturbed moves are left out).",
            a.method,
            a.config.name,
            short(&a.config_sha256, 12),
            a.software_version,
            hw.len(),
            hw.first().map_or("–", |r| r.name.as_str()),
            hw.last().map_or("–", |r| r.name.as_str()),
            a.moves.len(),
            a.moves.iter().filter(|m| counted(m)).count(),
        ),
        "Each move's travel is measured twice: by the motor's own position reads (**encoder**) and by the phone on the tube (**phone**). A **reversal** moves against the axis's previous motion; a **repeat** continues it.".into(),
        "**Reversal error** (over-correction): how much further the tube moves on a reversal than on a repeat. 0 is ideal; negative is slack left, positive is the anti-backlash overshooting. **Slack**: the lost motion a reversal crosses. ± is one standard error.".into(),
    ]));

    d.extend(facts(a));

    d.push(Heading(2, "Recommended anti-backlash".into()));
    d.push(Para(format!(
        "Chosen for the arrow keys' fine rates (keypad rates 1–{}): among the settings where each of those move types was tried, the one whose reversals have the smallest mean |reversal error|.",
        a.config.recommend.max_keypad_rate
    )));
    d.push(Table(
        [
            "Axis",
            "Recommended (arrow keys)",
            "In the last run",
            "For timed moves",
            "Based on",
        ]
        .map(String::from)
        .to_vec(),
        a.recommendations
            .iter()
            .map(|r| {
                vec![
                    r.axis.name().into(),
                    r.keypad
                        .best
                        .map_or("not enough data".into(), |b| format!("**{b}**")),
                    r.configured.map_or("–".into(), |c| c.to_string()),
                    r.timed.best.map_or("–".into(), |b| b.to_string()),
                    if r.keypad.kinds.is_empty() {
                        "–".into()
                    } else {
                        r.keypad.kinds.join("; ")
                    },
                ]
            })
            .collect(),
    ));
    let disagree: Vec<String> = a
        .recommendations
        .iter()
        .filter_map(|r| match (r.keypad.best, r.configured) {
            (Some(b), Some(c)) if b != c => Some(format!(
                "{}: {c} in the last run, {b} recommended",
                r.axis.name()
            )),
            _ => None,
        })
        .collect();
    if !disagree.is_empty() {
        d.push(Para(format!("**The last run used a different setting**: {}. Check `config/mount.toml` and the mount hold the recommended values.", disagree.join("; "))));
    }

    d.push(Heading(2, "Performance at the recommended settings".into()));
    let rows = performance(a);
    if rows.is_empty() {
        d.push(Para(
            "No move type was measured at a recommended setting.".into(),
        ));
    } else {
        d.push(Image(
            "performance.svg".into(),
            "Reversal error at the recommended settings, against the slack left uncorrected".into(),
        ));
        d.push(Table(
            [
                "Moves",
                "Anti-backlash",
                "Reversals",
                "Reversal error",
                "Uncorrected (slack)",
                "",
            ]
            .map(String::from)
            .to_vec(),
            rows.iter()
                .map(|r| {
                    vec![
                        format!("{} {}", r.axis.name(), r.group.label),
                        r.group.anti_backlash.to_string(),
                        r.group.reversals.as_ref().map_or(0, |s| s.n).to_string(),
                        est(r.group.over_correction),
                        r.group
                            .slack
                            .map_or("–".into(), |s| format!("{:+.0}″", -s.value)),
                        if r.compensated {
                            String::new()
                        } else {
                            r.note.clone()
                        },
                    ]
                })
                .collect(),
        ));
    }

    d.extend(evidence(a, images, speeds, latency));
    d
}

/// What's established about the mount: identity and settings, position
/// scale, which commands anti-backlash acts on, and protocol findings.
fn facts(a: &MountAnalysis) -> Vec<Block> {
    use Block::*;
    let mut d = vec![Heading(2, "What we know about this mount".into())];
    let mut items = Vec::new();
    if let Some(x) = &a.discovery {
        let mut mount = vec![];
        if let Some(m) = &x.model {
            mount.push(format!("model {m}"));
        }
        if let Some(h) = &x.hand_controller {
            mount.push(format!("hand controller {h}"));
        }
        if !x.motors.is_empty() {
            mount.push(format!(
                "motor controllers {} (azimuth, altitude)",
                x.motors.join(" and ")
            ));
        }
        if let Some(u) = &x.usb {
            mount.push(format!(
                "USB serial bridge {u}{}",
                x.link.as_ref().map_or(String::new(), |l| format!(", {l}"))
            ));
        }
        if let Some(ms) = x.position_reply_ms {
            mount.push(format!("a position query answers in about {ms:.0} ms"));
        }
        items.push(format!(
            "**Mount** (discovery `{}`{}): {}.",
            x.name,
            if x.simulated { ", simulated" } else { "" },
            mount.join("; ")
        ));
        let mut settings = vec![];
        if let Some(b) = x.anti_backlash {
            settings.push(format!(
                "anti-backlash azimuth +{} −{}, altitude +{} −{} when read",
                b[0], b[1], b[2], b[3]
            ));
        }
        if let [Some(az), Some(alt)] = &x.approach {
            settings.push(format!(
                "goto approach azimuth {az}, altitude {alt} (gotos sent by position don't use it)"
            ));
        }
        if let Some(i) = &x.azimuth_index {
            settings.push(format!("azimuth index marker: {i}"));
        }
        if !settings.is_empty() {
            items.push(format!(
                "**Motor controller settings:** {}.",
                settings.join("; ")
            ));
        }
    }
    let units_per_deg = 16_777_216.0 / 360.0;
    let mut scale = format!(
        "**Position scale:** 2²⁴ = 16,777,216 units per revolution: {} units per degree, {:.1} per arcsecond (one unit is {:.3}″).",
        thousands(units_per_deg),
        units_per_deg / 3600.0,
        3600.0 / units_per_deg
    );
    let checks: Vec<String> = a
        .scale
        .iter()
        .map(|c| {
            format!(
                "{} {}",
                c.axis.name(),
                match c.ratio.se {
                    Some(se) => format!("{:.3} ± {se:.3}", c.ratio.value),
                    None => format!("{:.3}", c.ratio.value),
                }
            )
        })
        .collect();
    if !checks.is_empty() {
        let _ = write!(
            scale,
            " The phone's travel over the encoder's on one-way moves of {:.1}° or more: {} (1 is exact; the phone's own scale and alignment are in it). Against gravity, altitude matches the nominal scale to about 0.3% (O12).",
            a.config.scale.min_travel_arcsec / 3600.0,
            checks.join(", ")
        );
    }
    items.push(scale);
    let r = a.config.geometry.leading_edge_radius_mm;
    let mm_per_deg = r * std::f64::consts::PI / 180.0;
    let mut edge = format!(
        "**At the leading edge** ({r:.0} mm from the axis, an estimate that varies with the tube's place in its bracket): 1 mm is {} units ({:.3}°); one unit is {:.2} µm.",
        thousands(units_per_deg / mm_per_deg),
        1.0 / mm_per_deg,
        mm_per_deg / units_per_deg * 1000.0
    );
    let slack: Vec<String> = a
        .slack_arcsec
        .iter()
        .map(|(axis, s)| {
            format!(
                "{} {s:.0}″ ({:.2} mm)",
                axis.name(),
                s / 3600.0 * mm_per_deg
            )
        })
        .collect();
    if !slack.is_empty() {
        let _ = write!(
            edge,
            " Typical slack crossed on a reversal: {}.",
            slack.join(", ")
        );
    }
    items.push(edge);
    d.push(List(items));

    if !a.applies.is_empty() {
        d.push(Para("**Which commands anti-backlash acts on** (motor take-up on reversals at a non-zero setting):".into()));
        let mut commands: Vec<&str> = Vec::new();
        for x in &a.applies {
            if !commands.contains(&x.commands.as_str()) {
                commands.push(&x.commands);
            }
        }
        let cell = |axis: Axis, c: &str| {
            a.applies
                .iter()
                .find(|x| x.axis == axis && x.commands == c)
                .map_or("–".into(), |x| {
                    let t = &x.takeup;
                    let value = if t.value.abs() < 0.5 {
                        "0″".to_string()
                    } else {
                        format!("{:+.0}″", t.value)
                    };
                    let margin =
                        t.se.filter(|se| *se >= 10.0)
                            .map_or(String::new(), |se| format!(" ± {se:.0}″"));
                    format!(
                        "{} ({value}{margin} at {})",
                        match x.acts {
                            crate::mount::Acts::Yes => "**yes**",
                            crate::mount::Acts::Partly => "**partly**",
                            crate::mount::Acts::No => "**no**",
                        },
                        x.anti_backlash
                    )
                })
        };
        d.push(Table(
            ["Commands", "Azimuth", "Altitude"]
                .map(String::from)
                .to_vec(),
            commands
                .iter()
                .map(|c| vec![describe(c), cell(Axis::Azimuth, c), cell(Axis::Altitude, c)])
                .collect(),
        ));
    }
    if !a.config.findings.protocol.is_empty() {
        d.push(Para("**Protocol findings:**".into()));
        d.push(List(a.config.findings.protocol.clone()));
    }
    d
}

/// A whole number with thousands separators: 46603.4 → "46,603".
fn thousands(v: f64) -> String {
    let digits = format!("{:.0}", v.abs());
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    if v < 0.0 { format!("-{out}") } else { out }
}

/// A command family's name for readers: "keypad r6" → "Keypad rate 6".
fn describe(c: &str) -> String {
    if let Some(r) = c.strip_prefix("keypad r") {
        format!("Keypad rate {r} (arrow keys)")
    } else if c == "timed" {
        "Variable-rate moves (timed)".into()
    } else if let Some(speed) = c.strip_prefix("goto ") {
        format!("Gotos by position, {speed}")
    } else {
        c.into()
    }
}

/// One move type's reversal error for the performance section.
struct Perf<'a> {
    axis: Axis,
    group: &'a Group,
    /// Chosen for (the arrow keys' fine rates at the recommended setting).
    compensated: bool,
    note: String,
}

impl Perf<'_> {
    fn short(&self) -> String {
        let ax = match self.axis {
            Axis::Azimuth => "az",
            Axis::Altitude => "alt",
        };
        let kind = match &self.group.kind {
            Kind::Keypad { rate, .. } => format!("r{rate}"),
            Kind::Timed { .. } => "timed".into(),
            Kind::Goto { fast, .. } => if *fast { "goto fast" } else { "goto" }.into(),
        };
        format!("{ax} {kind}")
    }
}

/// The arrow keys' fine rates at the recommended setting, then what that
/// setting doesn't compensate: gotos and the faster keypad rates.
fn performance(a: &MountAnalysis) -> Vec<Perf<'_>> {
    let mut rows = Vec::new();
    for r in &a.recommendations {
        let Some(best) = r.keypad.best else {
            continue;
        };
        let on_axis = |f: &dyn Fn(&Group) -> bool| -> Vec<&Group> {
            a.groups
                .iter()
                .filter(|g| {
                    g.axis == r.axis
                        && crate::mount::comparable(g)
                        && g.over_correction.is_some()
                        && f(g)
                })
                .collect()
        };
        for kind in &r.keypad.kinds {
            if let Some(g) = on_axis(&|g| &g.label == kind && g.anti_backlash == best).first() {
                rows.push(Perf {
                    axis: r.axis,
                    group: g,
                    compensated: true,
                    note: String::new(),
                });
            }
        }
        // Per goto speed and per fast rate: the group at the recommended
        // setting if there is one, else the most-measured one.
        let mut extra: Vec<(String, &Group)> = Vec::new();
        let max = a.config.recommend.max_keypad_rate;
        for g in on_axis(&|g| match g.kind {
            Kind::Goto { approach, .. } => !approach,
            Kind::Keypad { rate, .. } => rate > max,
            Kind::Timed { .. } => false,
        }) {
            let key = match &g.kind {
                Kind::Goto { fast, .. } => format!("goto {fast}"),
                Kind::Keypad { rate, .. } => format!("r{rate}"),
                Kind::Timed { .. } => unreachable!(),
            };
            let n = |g: &Group| g.reversals.as_ref().map_or(0, |s| s.n);
            let better = |old: &Group| {
                (g.anti_backlash == best) as u8 > (old.anti_backlash == best) as u8
                    || ((g.anti_backlash == best) == (old.anti_backlash == best) && n(g) > n(old))
            };
            match extra.iter_mut().find(|(k, _)| *k == key) {
                Some(slot) if better(slot.1) => slot.1 = g,
                Some(_) => {}
                None => extra.push((key, g)),
            }
        }
        for (_, g) in extra {
            let note = match g.kind {
                Kind::Goto { .. } => "gotos: anti-backlash doesn't act".to_string(),
                _ if g.anti_backlash != best => {
                    format!("fast rate: measured at {}", g.anti_backlash)
                }
                _ => "fast rate: take-up partial or none".to_string(),
            };
            rows.push(Perf {
                axis: r.axis,
                group: g,
                compensated: false,
                note,
            });
        }
    }
    rows
}

fn performance_svg(a: &MountAnalysis) -> Option<String> {
    let rows = performance(a);
    if rows.is_empty() {
        return None;
    }
    let x = |i: usize| (i + 1) as f64;
    let series = vec![
        Series {
            name: "recommended".into(),
            points: rows
                .iter()
                .enumerate()
                .filter(|(_, r)| r.compensated)
                .filter_map(|(i, r)| r.group.over_correction.map(|e| (x(i), e.value, e.se)))
                .collect(),
            line: false,
            marker: true,
        },
        Series {
            name: "uncorrected slack".into(),
            points: rows
                .iter()
                .enumerate()
                .filter(|(_, r)| r.compensated)
                .filter_map(|(i, r)| r.group.slack.map(|s| (x(i) + 0.2, -s.value, s.se)))
                .collect(),
            line: false,
            marker: true,
        },
        Series {
            name: "not compensated".into(),
            points: rows
                .iter()
                .enumerate()
                .filter(|(_, r)| !r.compensated)
                .filter_map(|(i, r)| r.group.over_correction.map(|e| (x(i), e.value, e.se)))
                .collect(),
            line: false,
            marker: true,
        },
    ];
    let (lo, hi) = bounds(
        series.iter().flat_map(|s| {
            s.points
                .iter()
                .flat_map(|p| [p.1 - p.2.unwrap_or(0.0), p.1 + p.2.unwrap_or(0.0)])
        }),
        &[0.0],
    );
    let labels: Vec<(f64, String)> = rows
        .iter()
        .enumerate()
        .map(|(i, r)| (x(i), r.short()))
        .collect();
    Some(chart(
        "Reversal error at the recommended settings (0 is ideal)",
        PlotAxis {
            label: "move type",
            lo: 0.4,
            hi: rows.len() as f64 + 0.6,
            log: false,
        },
        PlotAxis {
            label: "reversal error (″)",
            lo,
            hi,
            log: false,
        },
        &series,
        &[0.0],
        Some(&labels),
    ))
}

fn evidence(
    a: &MountAnalysis,
    images: &[(Axis, Measure, String)],
    speeds: bool,
    latency: bool,
) -> Vec<Block> {
    use Block::*;
    let mut d = vec![Heading(2, "Supporting evidence".into())];
    let hw: Vec<_> = a
        .runs
        .iter()
        .filter(|r| r.hardware != Some(false))
        .collect();
    for axis in [Axis::Azimuth, Axis::Altitude] {
        let groups: Vec<&Group> = a
            .groups
            .iter()
            .filter(|g| g.axis == axis && shown(g))
            .collect();
        d.push(Heading(3, format!("Backlash by setting: {}", axis.name())));
        if groups.is_empty() {
            d.push(Para(format!(
                "No {} group has {MIN_SIDE} or more repeats and reversals.",
                axis.name()
            )));
            continue;
        }
        d.push(Table(
            [
                "Moves",
                "Anti-backlash",
                "Repeats / reversals",
                "Motor take-up",
                "Over-correction",
                "Slack",
            ]
            .map(String::from)
            .to_vec(),
            groups
                .iter()
                .map(|g| {
                    vec![
                        g.label.clone(),
                        g.anti_backlash.to_string(),
                        format!(
                            "{} / {}",
                            g.repeats.as_ref().map_or(0, |s| s.n),
                            g.reversals.as_ref().map_or(0, |s| s.n)
                        ),
                        est(g.takeup),
                        est(g.over_correction),
                        est(g.slack),
                    ]
                })
                .collect(),
        ));
        for (ax, measure, name) in images {
            if *ax == axis {
                let alt = match measure {
                    Measure::OverCorrection => {
                        "Over-correction against anti-backlash (kinds tried at two or more settings)"
                    }
                    Measure::Takeup => "Motor take-up against anti-backlash",
                    Measure::Spread => "Phone minus encoder for every move",
                };
                d.push(Image(name.clone(), format!("{alt}, {}", axis.name())));
            }
        }
    }

    d.push(Heading(3, "Keypad speeds".into()));
    if a.speeds.is_empty() {
        d.push(Para("No keypad-rate repeats.".into()));
    } else {
        d.push(Para("Encoder travel on repeats over the time from sending the move to sending the stop (includes the speed ramps), against Celestron's list.".into()));
        d.push(Table(
            [
                "Axis",
                "Rate",
                "Moves",
                "Measured °/s",
                "Celestron °/s",
                "Ratio",
            ]
            .map(String::from)
            .to_vec(),
            a.speeds
                .iter()
                .map(|s| {
                    vec![
                        s.axis.name().into(),
                        s.rate.to_string(),
                        s.n.to_string(),
                        format!("{:.4}", s.median_deg_s),
                        format!("{:.4}", s.celestron_deg_s),
                        format!("{:.2}", s.median_deg_s / s.celestron_deg_s),
                    ]
                })
                .collect(),
        ));
        if speeds {
            d.push(Image(
                "keypad_speeds.svg".into(),
                "Keypad speeds against Celestron's list".into(),
            ));
        }
    }

    d.push(Heading(3, "Link health".into()));
    d.push(Para(format!(
        "**Commands**: each command exchange's time from sending to the reply (the run logs time commands, not position reads); stalls are over {} ms. **Reads**: gaps between position reads while no command is in flight, normally about 260 ms; stalls are over {} ms (O7).",
        a.config.link.stall_ms, a.config.link.read_stall_ms
    )));
    d.push(Table(
        [
            "Run",
            "Commands",
            "Failures",
            "Median ms",
            "Longest ms",
            "Stalls",
            "Read gaps",
            "Median ms",
            "95th % ms",
            "Longest ms",
            "Stalls",
        ]
        .map(String::from)
        .to_vec(),
        a.links
            .iter()
            .filter(|l| l.exchanges > 0 || l.read_gaps > 0)
            .map(|l| {
                vec![
                    l.run.clone(),
                    l.exchanges.to_string(),
                    l.failures.to_string(),
                    opt(l.median_ms, 0),
                    opt(l.max_ms, 0),
                    l.stalls.to_string(),
                    l.read_gaps.to_string(),
                    opt(l.read_gap_median_ms, 0),
                    opt(l.read_gap_p95_ms, 0),
                    opt(l.read_gap_max_ms, 0),
                    l.read_stalls.to_string(),
                ]
            })
            .collect(),
    ));
    if latency {
        d.push(Image(
            "latency.svg".into(),
            "Distributions of command latency and idle read gaps".into(),
        ));
    }

    d.push(Heading(3, "Lifecycles, faults and notes".into()));
    let mut items = Vec::new();
    for r in &hw {
        for i in &r.incomplete {
            items.push(format!("{}: incomplete: {i}", r.name));
        }
        for f in &r.faults {
            items.push(format!("{}: fault: {f}", r.name));
        }
        for n in &r.notes {
            items.push(format!("{}: note at {n}", r.name));
        }
    }
    let incomplete: usize = hw.iter().map(|r| r.incomplete.len()).sum();
    d.push(Para(format!(
        "{} request(s), {} record(s); {incomplete} without a complete lifecycle.",
        hw.iter().map(|r| r.requests).sum::<usize>(),
        hw.iter().map(|r| r.records).sum::<usize>()
    )));
    if !items.is_empty() {
        d.push(List(items));
    }

    let disturbed: Vec<&Move> = a.moves.iter().filter(|m| m.disturbed).collect();
    if !disturbed.is_empty() {
        d.push(Heading(3, "Disturbed moves".into()));
        d.push(Para(format!(
            "Phone − encoder more than {} robust deviations and {}″ from the median of the move's group and history; left out of the statistics.",
            a.config.outliers.robust_k, a.config.outliers.min_arcsec
        )));
        d.push(Table(
            [
                "Run",
                "Command",
                "Axis",
                "Moves",
                "History",
                "Encoder ″",
                "Phone ″",
            ]
            .map(String::from)
            .to_vec(),
            disturbed
                .iter()
                .map(|m| {
                    vec![
                        m.run.clone(),
                        m.command_id.to_string(),
                        m.axis.name().into(),
                        m.kind.label(),
                        history(m.history).into(),
                        opt(m.encoder_arcsec, 1),
                        opt(m.phone_arcsec, 1),
                    ]
                })
                .collect(),
        ));
    }

    d.push(Heading(3, "Runs".into()));
    d.push(Table(
        ["Run", "SHA-256", "Anti-backlash", "Moves", "Faults"]
            .map(String::from)
            .to_vec(),
        a.runs
            .iter()
            .map(|r| {
                vec![
                    if r.hardware == Some(false) {
                        format!("{} (simulated, skipped)", r.name)
                    } else {
                        r.name.clone()
                    },
                    format!("`{}`", short(&r.sha256, 12)),
                    r.anti_backlash
                        .map_or("0 (assumed: the runner required it)".into(), |v| {
                            format!("{}, {}, {}, {}", v[0], v[1], v[2], v[3])
                        }),
                    r.moves.to_string(),
                    r.faults.len().to_string(),
                ]
            })
            .collect(),
    ));

    d.push(Heading(3, "Not recorded or not yet analysed".into()));
    d.push(List(vec![
        "Pose, balance and attachment: not in the run logs. Tube angle, balance changes (O13) and the phone's attachment are in docs/observations.md.".into(),
        "Per-move traces of encoder and phone angle through a reversal, and tube angle per move: need the phone's samples from the database.".into(),
        "Optical truth: the daytime camera check (ADR 0015) and plate solving (Prompt 9).".into(),
    ]));
    d
}

fn counted(m: &Move) -> bool {
    m.fault.is_none()
        && m.outcome == "completed"
        && m.history != History::Unknown
        && m.encoder_arcsec.is_some()
        && m.phone_arcsec.is_some()
        && !m.disturbed
}

fn history(h: History) -> &'static str {
    match h {
        History::Reversal => "reversal",
        History::Repeat => "repeat",
        History::Unknown => "unknown",
    }
}

fn est(e: Option<Estimate>) -> String {
    match e {
        None => "–".into(),
        Some(Estimate { value, se: None }) => format!("{value:+.0}″"),
        Some(Estimate {
            value,
            se: Some(se),
        }) if se < 0.5 => format!("{value:+.0} ± <1″"),
        Some(Estimate {
            value,
            se: Some(se),
        }) => format!("{value:+.0} ± {se:.0}″"),
    }
}

fn opt(v: Option<f64>, digits: usize) -> String {
    v.map_or(String::new(), |v| format!("{v:.digits$}"))
}

fn short(s: &str, n: usize) -> &str {
    s.get(..n).unwrap_or(s)
}

// --- CSV ---------------------------------------------------------------------

fn moves_csv(a: &MountAnalysis) -> String {
    let mut out = "run,command_id,axis,kind,rate,size,anti_backlash,anti_backlash_assumed,sign,history,outcome,fault,t_s,duration_s,commanded_arcsec,encoder_arcsec,phone_arcsec,phone_minus_encoder_arcsec,disturbed\n".to_string();
    for m in &a.moves {
        let (kind, rate, size) = match &m.kind {
            Kind::Keypad { rate, duration_ms } => {
                ("keypad", rate.to_string(), format!("{duration_ms} ms"))
            }
            Kind::Timed {
                rate_deg_s,
                duration_ms,
            } => ("timed", rate_deg_s.to_string(), format!("{duration_ms} ms")),
            Kind::Goto {
                fast,
                delta_deg,
                approach,
            } => (
                if *approach { "goto_approach" } else { "goto" },
                if *fast { "fast" } else { "slow" }.to_string(),
                format!("{delta_deg} deg"),
            ),
        };
        let _ = writeln!(
            out,
            "{},{},{},{kind},{rate},{size},{},{},{},{},{},{},{:.3},{},{},{},{},{},{}",
            m.run,
            m.command_id,
            m.axis.name(),
            m.anti_backlash,
            m.anti_backlash_assumed,
            m.sign,
            history(m.history),
            m.outcome,
            m.fault.as_deref().unwrap_or(""),
            m.t_s,
            opt(m.duration_s, 3),
            opt(m.commanded_arcsec, 2),
            opt(m.encoder_arcsec, 2),
            opt(m.phone_arcsec, 2),
            opt(m.residual(), 2),
            m.disturbed
        );
    }
    out
}

fn groups_csv(a: &MountAnalysis) -> String {
    let mut out = "axis,moves,anti_backlash,repeats,reversals,encoder_repeat,encoder_reversal,phone_repeat,phone_reversal,takeup,takeup_se,over_correction,over_correction_se,slack,slack_se,runs\n".to_string();
    let v = |e: Option<Estimate>| opt(e.map(|e| e.value), 2);
    let se = |e: Option<Estimate>| opt(e.and_then(|e| e.se), 2);
    for g in &a.groups {
        let (rep, rev) = (g.repeats.as_ref(), g.reversals.as_ref());
        let _ = writeln!(
            out,
            "{},\"{}\",{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
            g.axis.name(),
            g.label,
            g.anti_backlash,
            rep.map_or(0, |s| s.n),
            rev.map_or(0, |s| s.n),
            v(rep.map(|s| s.encoder)),
            v(rev.map(|s| s.encoder)),
            v(rep.map(|s| s.phone)),
            v(rev.map(|s| s.phone)),
            v(g.takeup),
            se(g.takeup),
            v(g.over_correction),
            se(g.over_correction),
            v(g.slack),
            se(g.slack),
            g.runs.join(" ")
        );
    }
    out
}

// --- Graphs ------------------------------------------------------------------

struct Series {
    name: String,
    /// (x, y, error)
    points: Vec<(f64, f64, Option<f64>)>,
    line: bool,
    marker: bool,
}

/// A graph with point markers, error bars, lines and horizontal reference
/// lines, in the bench report's style.
fn chart(
    title: &str,
    x: PlotAxis,
    y: PlotAxis,
    series: &[Series],
    hlines: &[f64],
    x_labels: Option<&[(f64, String)]>,
) -> String {
    let px = |v: f64| x.map(v, LEFT, W - RIGHT);
    let py = |v: f64| y.map(v.clamp(y.lo, y.hi), H - BOTTOM, TOP);
    let mut s = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {W} {H}\" width=\"{W}\" height=\"{H}\" font-family=\"-apple-system, system-ui, sans-serif\" font-size=\"12\">\n<rect width=\"{W}\" height=\"{H}\" fill=\"#ffffff\"/>\n<text x=\"{LEFT}\" y=\"20\" font-size=\"14\" font-weight=\"600\">{}</text>\n",
        escape(title)
    );
    let xticks: Vec<(f64, String)> = match x_labels {
        Some(l) => l.to_vec(),
        None => x.ticks().into_iter().map(|t| (t, tick(t))).collect(),
    };
    for (t, label) in &xticks {
        let _ = writeln!(
            s,
            "<line x1=\"{0:.1}\" y1=\"{TOP}\" x2=\"{0:.1}\" y2=\"{1}\" stroke=\"#e5e5ea\"/>\n<text x=\"{0:.1}\" y=\"{2}\" text-anchor=\"middle\">{3}</text>",
            px(*t),
            H - BOTTOM,
            H - BOTTOM + 16.0,
            escape(label)
        );
    }
    for t in y.ticks() {
        let _ = writeln!(
            s,
            "<line x1=\"{LEFT}\" y1=\"{0:.1}\" x2=\"{1}\" y2=\"{0:.1}\" stroke=\"#e5e5ea\"/>\n<text x=\"{2}\" y=\"{3:.1}\" text-anchor=\"end\">{4}</text>",
            py(t),
            W - RIGHT,
            LEFT - 6.0,
            py(t) + 4.0,
            tick(t)
        );
    }
    for h in hlines {
        if *h >= y.lo && *h <= y.hi {
            let _ = writeln!(
                s,
                "<line x1=\"{LEFT}\" y1=\"{0:.1}\" x2=\"{1}\" y2=\"{0:.1}\" stroke=\"#515154\" stroke-width=\"1\"/>",
                py(*h),
                W - RIGHT
            );
        }
    }
    let _ = writeln!(
        s,
        "<rect x=\"{LEFT}\" y=\"{TOP}\" width=\"{}\" height=\"{}\" fill=\"none\" stroke=\"#86868b\"/>\n<text x=\"{}\" y=\"{}\" text-anchor=\"middle\">{}</text>\n<text transform=\"translate(16 {}) rotate(-90)\" text-anchor=\"middle\">{}</text>",
        W - LEFT - RIGHT,
        H - TOP - BOTTOM,
        (LEFT + W - RIGHT) / 2.0,
        H - 10.0,
        escape(x.label),
        (TOP + H - BOTTOM) / 2.0,
        escape(y.label)
    );
    for (i, ser) in series.iter().enumerate() {
        let color = COLORS[i % COLORS.len()];
        let pts: Vec<&(f64, f64, Option<f64>)> = ser
            .points
            .iter()
            .filter(|(a, b, _)| (!x.log || *a > 0.0) && (!y.log || *b > 0.0))
            .collect();
        if ser.line && pts.len() > 1 {
            let path: Vec<String> = pts
                .iter()
                .map(|(a, b, _)| format!("{:.1},{:.1}", px(*a), py(*b)))
                .collect();
            let _ = writeln!(
                s,
                "<polyline fill=\"none\" stroke=\"{color}\" stroke-width=\"1.5\" points=\"{}\"/>",
                path.join(" ")
            );
        }
        if ser.marker {
            for (a, b, e) in &pts {
                if let Some(e) = e {
                    let _ = writeln!(
                        s,
                        "<line x1=\"{0:.1}\" y1=\"{1:.1}\" x2=\"{0:.1}\" y2=\"{2:.1}\" stroke=\"{color}\"/>",
                        px(*a),
                        py(b - e),
                        py(b + e)
                    );
                }
                let _ = writeln!(
                    s,
                    "<circle cx=\"{:.1}\" cy=\"{:.1}\" r=\"3\" fill=\"{color}\"/>",
                    px(*a),
                    py(*b)
                );
            }
        }
        let ly = TOP + 10.0 + i as f64 * 18.0;
        let _ = writeln!(
            s,
            "<line x1=\"{0}\" y1=\"{1:.1}\" x2=\"{2}\" y2=\"{1:.1}\" stroke=\"{color}\" stroke-width=\"2\"/>\n<text x=\"{3}\" y=\"{4:.1}\">{5}</text>",
            W - RIGHT + 10.0,
            ly,
            W - RIGHT + 30.0,
            W - RIGHT + 36.0,
            ly + 4.0,
            escape(&ser.name)
        );
    }
    s.push_str("</svg>\n");
    s
}

/// Rounded-out bounds holding `values` and `include`, with a margin.
fn bounds(values: impl Iterator<Item = f64>, include: &[f64]) -> (f64, f64) {
    let (mut lo, mut hi) = (f64::MAX, f64::MIN);
    for v in values.chain(include.iter().copied()) {
        lo = lo.min(v);
        hi = hi.max(v);
    }
    if lo > hi {
        return (0.0, 1.0);
    }
    let pad = ((hi - lo) * 0.08).max(1.0);
    let step = 10f64
        .powf(((hi - lo + 2.0 * pad).log10() - 1.0).floor())
        .max(1.0);
    (
        ((lo - pad) / step).floor() * step,
        ((hi + pad) / step).ceil() * step,
    )
}

fn sweep_svg(a: &MountAnalysis, axis: Axis, measure: Measure) -> Option<String> {
    let groups: Vec<&Group> = a
        .groups
        .iter()
        .filter(|g| g.axis == axis && shown(g))
        .collect();
    // Only kinds tried at two or more settings: one-off trials stay in the tables.
    let mut labels: Vec<String> = Vec::new();
    for g in &groups {
        if !labels.contains(&g.label) && groups.iter().filter(|h| h.label == g.label).count() > 1 {
            labels.push(g.label.clone());
        }
    }
    let series: Vec<Series> = labels
        .iter()
        .map(|label| Series {
            name: label.clone(),
            points: groups
                .iter()
                .filter(|g| &g.label == label)
                .filter_map(|g| {
                    let e = match measure {
                        Measure::Takeup => g.takeup,
                        _ => g.over_correction,
                    }?;
                    Some((f64::from(g.anti_backlash), e.value, e.se))
                })
                .collect(),
            line: true,
            marker: true,
        })
        .collect();
    if series.iter().all(|s| s.points.is_empty()) {
        return None;
    }
    let ys = series.iter().flat_map(|s| {
        s.points
            .iter()
            .flat_map(|p| [p.1 - p.2.unwrap_or(0.0), p.1 + p.2.unwrap_or(0.0)])
    });
    let (ylo, yhi) = bounds(ys, &[0.0]);
    let xmax = groups
        .iter()
        .map(|g| f64::from(g.anti_backlash))
        .fold(0.0, f64::max);
    let (title, ylabel) = match measure {
        Measure::Takeup => (
            format!("Motor take-up on reversal, {}", axis.name()),
            "encoder extra on reversal (″)",
        ),
        _ => (
            format!("Over-correction on reversal, {} (0 is ideal)", axis.name()),
            "phone extra on reversal (″)",
        ),
    };
    Some(chart(
        &title,
        PlotAxis {
            label: "anti-backlash setting",
            lo: -5.0,
            hi: (xmax + 10.0).max(65.0),
            log: false,
        },
        PlotAxis {
            label: ylabel,
            lo: ylo,
            hi: yhi,
            log: false,
        },
        &series,
        &[0.0],
        None,
    ))
}

fn spread_svg(a: &MountAnalysis, axis: Axis) -> Option<String> {
    let moves: Vec<&Move> = a
        .moves
        .iter()
        .filter(|m| {
            m.axis == axis
                && m.fault.is_none()
                && m.outcome == "completed"
                && m.history != History::Unknown
                && m.residual().is_some()
        })
        .collect();
    if moves.is_empty() {
        return None;
    }
    let pick = |f: &dyn Fn(&Move) -> bool, dx: f64| -> Vec<(f64, f64, Option<f64>)> {
        moves
            .iter()
            .filter(|m| f(m))
            .map(|m| {
                (
                    f64::from(m.anti_backlash) + dx,
                    m.residual().unwrap_or(0.0),
                    None,
                )
            })
            .collect()
    };
    let series = vec![
        Series {
            name: "reversals".into(),
            points: pick(&|m| m.history == History::Reversal && !m.disturbed, -1.2),
            line: false,
            marker: true,
        },
        Series {
            name: "repeats".into(),
            points: pick(&|m| m.history == History::Repeat && !m.disturbed, 1.2),
            line: false,
            marker: true,
        },
        Series {
            name: "disturbed".into(),
            points: pick(&|m| m.disturbed, 0.0),
            line: false,
            marker: true,
        },
    ];
    let (ylo, yhi) = bounds(
        series.iter().flat_map(|s| s.points.iter().map(|p| p.1)),
        &[0.0],
    );
    let xmax = moves
        .iter()
        .map(|m| f64::from(m.anti_backlash))
        .fold(0.0, f64::max);
    Some(chart(
        &format!(
            "Phone − encoder per move, {} (lost motion is negative)",
            axis.name()
        ),
        PlotAxis {
            label: "anti-backlash setting",
            lo: -5.0,
            hi: (xmax + 10.0).max(65.0),
            log: false,
        },
        PlotAxis {
            label: "phone − encoder (″)",
            lo: ylo,
            hi: yhi,
            log: false,
        },
        &series,
        &[0.0],
        None,
    ))
}

fn speeds_svg(a: &MountAnalysis) -> String {
    let mut series: Vec<Series> = [Axis::Azimuth, Axis::Altitude]
        .into_iter()
        .filter(|ax| a.speeds.iter().any(|s| s.axis == *ax))
        .map(|ax| Series {
            name: format!("{} measured", ax.name()),
            points: a
                .speeds
                .iter()
                .filter(|s| s.axis == ax)
                .map(|s| (f64::from(s.rate), s.median_deg_s, None))
                .collect(),
            line: false,
            marker: true,
        })
        .collect();
    series.push(Series {
        name: "Celestron's list".into(),
        points: crate::mount::CELESTRON_RATES_DEG_S
            .iter()
            .enumerate()
            .map(|(i, v)| ((i + 1) as f64, *v, None))
            .collect(),
        line: true,
        marker: false,
    });
    let labels: Vec<(f64, String)> = (1..=9).map(|r| (f64::from(r), r.to_string())).collect();
    chart(
        "Keypad rate speeds",
        PlotAxis {
            label: "keypad rate",
            lo: 0.5,
            hi: 9.5,
            log: false,
        },
        PlotAxis {
            label: "°/s",
            lo: 0.001,
            hi: 10.0,
            log: true,
        },
        &series,
        &[],
        Some(&labels),
    )
}

fn latency_svg(a: &MountAnalysis) -> String {
    let cdf = |v: &[f64]| -> Vec<(f64, f64, Option<f64>)> {
        let n = v.len();
        if n == 0 {
            return Vec::new();
        }
        let step = n.div_ceil(1500).max(1);
        (0..n)
            .step_by(step)
            .chain(std::iter::once(n - 1))
            .map(|i| (v[i].max(1.0), (i + 1) as f64 / n as f64, None))
            .collect()
    };
    let top = a
        .latencies_ms
        .iter()
        .chain(&a.read_gaps_ms)
        .copied()
        .fold(10.0, f64::max);
    chart(
        "Command latency and idle read gaps, all runs",
        PlotAxis {
            label: "milliseconds",
            lo: 10.0,
            hi: 10f64.powf(top.log10().ceil()),
            log: true,
        },
        PlotAxis {
            label: "fraction at or below",
            lo: 0.0,
            hi: 1.0,
            log: false,
        },
        &[
            Series {
                name: format!("commands ({})", a.latencies_ms.len()),
                points: cdf(&a.latencies_ms),
                line: true,
                marker: false,
            },
            Series {
                name: format!("read gaps ({})", a.read_gaps_ms.len()),
                points: cdf(&a.read_gaps_ms),
                line: true,
                marker: false,
            },
        ],
        &[],
        None,
    )
}
