//! Report files for an [`Analysis`]: Markdown and HTML with the same content,
//! JSON metrics, CSV tables and SVG plots. Output depends only on the
//! analysis, so the same session and config give byte-identical files.

use std::fmt::Write as _;

use crate::{
    data::SessionData,
    stationary::{Analysis, Outcome},
};

/// A generated file: name and contents.
pub type File = (&'static str, String);

pub fn render(analysis: &Analysis, data: &SessionData) -> Vec<File> {
    let doc = document(analysis);
    let mut files = vec![
        ("report.md", markdown(&doc)),
        ("report.html", html(&doc, &title(analysis))),
        (
            "metrics.json",
            serde_json::to_string_pretty(analysis).expect("serializable") + "\n",
        ),
        ("windows.csv", windows_csv(analysis)),
        ("timeline.svg", timeline_svg(analysis, data)),
    ];
    if let Some(r) = &analysis.resolution {
        files.push(("resolution.csv", resolution_csv(analysis)));
        let angles: Vec<usize> = (0..r.channels.len())
            .filter(|&i| r.channels[i].1 == "deg")
            .collect();
        let rates: Vec<usize> = (0..r.channels.len())
            .filter(|&i| r.channels[i].1 == "deg/s")
            .collect();
        files.push((
            "resolution_angles.svg",
            adev_svg(
                analysis,
                &angles,
                "Angle comparison noise (Allan deviation)",
                "deg",
            ),
        ));
        if !rates.is_empty() {
            files.push((
                "resolution_gyro.svg",
                adev_svg(analysis, &rates, "Raw gyro Allan deviation", "deg/s"),
            ));
        }
    }
    files
}

fn title(a: &Analysis) -> String {
    format!("Bench report: session {}", short(&a.source.session_id))
}

enum Block {
    Heading(u8, String),
    Para(String),
    List(Vec<String>),
    Table(Vec<String>, Vec<Vec<String>>),
    Image(String, String),
}

fn document(a: &Analysis) -> Vec<Block> {
    use Block::*;
    let mut d = vec![Heading(1, title(a))];
    let s = &a.source;
    d.push(List(vec![
        format!("Session `{}`, device `{}`", s.session_id, s.device_id),
        format!(
            "Recorded {} ({}), {:.1} s",
            s.created_utc, s.status, a.duration_s
        ),
        format!(
            "App {}, reference frame {}, requested interval {}",
            s.app_version.as_deref().unwrap_or("?"),
            s.attitude_reference_frame.as_deref().unwrap_or("?"),
            s.requested_interval_s
                .map_or("?".into(), |i| format!("{:.1} ms", i * 1e3))
        ),
        format!("Data: session export SHA-256 `{}`", s.export_sha256),
        format!(
            "Config `{}` (version {}), SHA-256 `{}`",
            a.config.name, a.config.version, a.config_sha256
        ),
        format!(
            "Software {}, method {}, database schema {}",
            a.software.analysis, a.software.method, a.software.database_schema
        ),
    ]));

    d.push(Heading(2, "Decision".into()));
    d.push(Para(format!("**{}**", a.decision)));
    d.push(Table(
        vec![
            "Check".into(),
            "Value".into(),
            "Limit".into(),
            "Result".into(),
        ],
        a.acceptance
            .iter()
            .map(|c| {
                vec![
                    c.name.clone(),
                    c.value.clone(),
                    c.limit.clone(),
                    match c.outcome {
                        Outcome::Pass => "pass",
                        Outcome::Fail => "FAIL",
                        Outcome::NotMeasured => "not measured",
                    }
                    .into(),
                ]
            })
            .collect(),
    ));

    d.push(Heading(2, "Timing".into()));
    d.push(Table(
        [
            "Stream",
            "Samples",
            "Rate",
            "Interval mean",
            "sd",
            "min",
            "max",
            "Long gaps",
        ]
        .map(String::from)
        .to_vec(),
        a.timing
            .streams
            .iter()
            .map(|t| {
                vec![
                    t.stream.into(),
                    t.samples.to_string(),
                    t.rate_hz.map_or("-".into(), |r| format!("{r:.3} Hz")),
                    t.interval
                        .map_or("-".into(), |i| format!("{:.4} ms", i.mean)),
                    t.interval.map_or("-".into(), |i| format!("{:.4} ms", i.sd)),
                    t.interval_min_ms
                        .map_or("-".into(), |v| format!("{v:.4} ms")),
                    t.interval_max_ms
                        .map_or("-".into(), |v| format!("{v:.4} ms")),
                    t.long_intervals.to_string(),
                ]
            })
            .collect(),
    ));
    d.push(Para(format!(
        "Missing sequence numbers: {} in {} range(s). Dropped on the phone before sequencing: {}.",
        a.timing.missing_samples,
        a.timing.missing.len(),
        a.timing.dropped_on_phone
    )));
    if a.timing.clock.is_empty() {
        d.push(Para(
            "Clock: no exchanges in this session, so phone-to-Mac alignment is unknown and only phone-time metrics are reported.".into(),
        ));
    } else {
        d.push(Table(
            [
                "Receiver run",
                "Exchanges (used)",
                "Round trip min / median",
                "Drift",
                "Uncertainty",
            ]
            .map(String::from)
            .to_vec(),
            a.timing
                .clock
                .iter()
                .map(|m| {
                    vec![
                        short(&m.mac_clock_boot_id).into(),
                        format!("{} ({})", m.exchanges, m.used),
                        format!(
                            "{:.2} / {:.2} ms",
                            m.round_trip_min_ns as f64 / 1e6,
                            m.round_trip_median_ns as f64 / 1e6
                        ),
                        if m.drift_fitted {
                            format!("{:+.2} ppm", m.drift_ppb / 1e3)
                        } else {
                            "not fitted".into()
                        },
                        format!("±{:.2} ms", m.uncertainty_ns as f64 / 1e6),
                    ]
                })
                .collect(),
        ));
    }

    d.push(Heading(2, "Still windows and exclusions".into()));
    d.push(Para(format!(
        "Still: fused rotation rate below {} °/s averaged over {} s, for at least {} s. Steady-state still time: {:.1} s.",
        a.config.still.max_rate_deg_s,
        a.config.still.smoothing_s,
        a.config.still.min_duration_s,
        a.steady_state_s
    )));
    if !a.exclusions.is_empty() {
        d.push(List(a.exclusions.clone()));
    }
    d.push(Table(
        [
            "#",
            "Start",
            "End",
            "Duration",
            "Gravity (device frame)",
            "Used",
            "Markers",
        ]
        .map(String::from)
        .to_vec(),
        a.windows
            .iter()
            .map(|w| {
                let markers: Vec<String> = a
                    .markers
                    .iter()
                    .filter(|m| m.window == Some(w.index))
                    .map(|m| m.label.clone())
                    .collect();
                vec![
                    w.index.to_string(),
                    format!("{:.2} s", w.start_s),
                    format!("{:.2} s", w.end_s),
                    format!("{:.2} s", w.duration_s),
                    vec3(w.gravity_device, 4),
                    if w.steady { "steady state" } else { "warm-up" }.into(),
                    markers.join(", "),
                ]
            })
            .collect(),
    ));
    let outside: Vec<String> = a
        .markers
        .iter()
        .filter(|m| m.window.is_none())
        .map(|m| format!("{} at {:.2} s (not in a still window)", m.label, m.t_s))
        .collect();
    if !outside.is_empty() {
        d.push(List(outside));
    }
    d.push(Image(
        "timeline.svg".into(),
        "Rotation rate with still windows".into(),
    ));

    d.push(Heading(2, "Noise and drift while still".into()));
    d.push(Para(
        "Tilt is the gravity direction's deviation from the window mean about two axes perpendicular to it: `a` is toward the device X axis (Y when X is vertical), `b` completes the pair. `tilt` uses the fused gravity estimate, `accel_tilt` the raw accelerometer. Heading is the rotation about the reference frame's vertical relative to the window's start. Gyro is the raw gyro, including its bias.".into(),
    ));
    for n in &a.noise {
        d.push(Heading(
            3,
            format!(
                "Window {} ({:.1} s{})",
                n.window,
                n.duration_s,
                n.accel_magnitude_g
                    .map_or(String::new(), |g| format!(", raw |a| {g:.5} g"))
            ),
        ));
        d.push(Table(
            ["Channel", "Mean", "sd", "MAD", "5th–95th", "Drift / min"]
                .map(String::from)
                .to_vec(),
            n.channels
                .iter()
                .map(|c| {
                    vec![
                        format!("{} ({})", c.name, c.unit),
                        sig(c.summary.mean),
                        sig(c.summary.sd),
                        sig(c.summary.mad),
                        format!("{} … {}", sig(c.summary.p05), sig(c.summary.p95)),
                        c.drift_per_min.map_or("-".into(), sig),
                    ]
                })
                .collect(),
        ));
    }

    if let Some(r) = &a.resolution {
        d.push(Heading(2, "Resolution versus window length".into()));
        d.push(Para(format!(
            "From window {}. Each value is the Allan deviation at averaging time τ: for angles, the noise in the difference between two adjacent still windows of length τ, divided by √2. The smallest step two windows can resolve is about {} × √2 × that value (k = {}). `tilt` and `heading` are Core Motion's filtered outputs, so their values at short τ understate the noise; read them at the settle-window length you intend to use. The minimum is searched from τ = {} s.",
            r.window, r.coverage_k, r.coverage_k, a.config.resolution.min_window_s
        )));
        let mut head = vec!["τ".to_string()];
        head.extend(r.channels.iter().map(|(n, u)| format!("{n} ({u})")));
        let mut rows: Vec<Vec<String>> = r
            .rows
            .iter()
            .map(|row| {
                let mut cells = vec![format!("{} s", row.tau_s)];
                cells.extend(row.adev.iter().map(|v| v.map_or("-".into(), sig)));
                cells
            })
            .collect();
        let mut min_row = vec!["minimum (at τ)".to_string()];
        min_row.extend(r.minimum.iter().map(|m| {
            m.map_or("-".into(), |(tau, v)| {
                format!("{} ({} s)", sig(v), sig(tau))
            })
        }));
        rows.push(min_row);
        let mut step_row = vec![format!("smallest step at minimum, k = {}", r.coverage_k)];
        step_row.extend(r.channels.iter().zip(&r.minimum).map(|((_, unit), m)| {
            if *unit == "deg" {
                m.map_or("-".into(), |(_, v)| {
                    sig(r.coverage_k * std::f64::consts::SQRT_2 * v)
                })
            } else {
                "-".into()
            }
        }));
        rows.push(step_row);
        d.push(Table(head, rows));
        d.push(Image(
            "resolution_angles.svg".into(),
            "Angle Allan deviation versus averaging time".into(),
        ));
        if r.channels.iter().any(|(_, u)| *u == "deg/s") {
            d.push(Image(
                "resolution_gyro.svg".into(),
                "Raw gyro Allan deviation versus averaging time".into(),
            ));
        }
    }

    if !a.moves.is_empty() {
        d.push(Heading(2, "Moves between still windows".into()));
        d.push(Para(
            "Rotation from one window's mean attitude to the next, with its axis in the first window's device frame; heading change about the vertical; and the change in gravity direction.".into(),
        ));
        d.push(Table(
            [
                "From → to",
                "Rotation",
                "Axis (device)",
                "Heading",
                "Gravity change",
            ]
            .map(String::from)
            .to_vec(),
            a.moves
                .iter()
                .map(|m| {
                    vec![
                        format!("{} → {}", m.from, m.to),
                        format!("{:.3}°", m.angle_deg),
                        vec3(m.axis_device, 3),
                        format!("{:+.3}°", m.heading_deg),
                        format!("{:.3}°", m.gravity_change_deg),
                    ]
                })
                .collect(),
        ));
    }

    d.push(Heading(2, "Not yet analysed".into()));
    d.push(List(vec![
        "Power spectral density.".into(),
        "Bootstrap confidence intervals across repeated trials.".into(),
        "Mount step sequences against commanded angles (with the test runner, ADR 0009).".into(),
        "Attachment remove-and-replace on the scope.".into(),
    ]));
    d
}

fn markdown(doc: &[Block]) -> String {
    let mut out = String::new();
    for block in doc {
        match block {
            Block::Heading(level, text) => {
                let _ = writeln!(out, "{} {text}\n", "#".repeat(*level as usize));
            }
            Block::Para(text) => {
                let _ = writeln!(out, "{text}\n");
            }
            Block::List(items) => {
                for item in items {
                    let _ = writeln!(out, "- {item}");
                }
                out.push('\n');
            }
            Block::Table(head, rows) => {
                let _ = writeln!(out, "| {} |", head.join(" | "));
                let _ = writeln!(out, "|{}", "---|".repeat(head.len()));
                for row in rows {
                    let _ = writeln!(out, "| {} |", row.join(" | "));
                }
                out.push('\n');
            }
            Block::Image(src, alt) => {
                let _ = writeln!(out, "![{alt}]({src})\n");
            }
        }
    }
    out
}

fn html(doc: &[Block], title: &str) -> String {
    let mut out = format!(
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>{}</title>\n<style>\nbody {{ font-family: -apple-system, system-ui, sans-serif; max-width: 72rem; margin: 2rem auto; padding: 0 1rem; color: #1d1d1f; background: #fff; }}\ntable {{ border-collapse: collapse; margin: 1rem 0; font-size: 0.9rem; }}\nth, td {{ border: 1px solid #d2d2d7; padding: 0.3rem 0.6rem; text-align: left; }}\nth {{ background: #f5f5f7; }}\ncode {{ font-size: 0.85em; }}\nimg {{ max-width: 100%; }}\n.table {{ overflow-x: auto; }}\n</style>\n</head>\n<body>\n",
        escape(title)
    );
    for block in doc {
        match block {
            Block::Heading(level, text) => {
                let _ = writeln!(out, "<h{level}>{}</h{level}>", inline(text));
            }
            Block::Para(text) => {
                let _ = writeln!(out, "<p>{}</p>", inline(text));
            }
            Block::List(items) => {
                out.push_str("<ul>\n");
                for item in items {
                    let _ = writeln!(out, "<li>{}</li>", inline(item));
                }
                out.push_str("</ul>\n");
            }
            Block::Table(head, rows) => {
                out.push_str("<div class=\"table\"><table>\n<tr>");
                for h in head {
                    let _ = write!(out, "<th>{}</th>", inline(h));
                }
                out.push_str("</tr>\n");
                for row in rows {
                    out.push_str("<tr>");
                    for cell in row {
                        let _ = write!(out, "<td>{}</td>", inline(cell));
                    }
                    out.push_str("</tr>\n");
                }
                out.push_str("</table></div>\n");
            }
            Block::Image(src, alt) => {
                let _ = writeln!(
                    out,
                    "<p><img src=\"{}\" alt=\"{}\"></p>",
                    escape(src),
                    escape(alt)
                );
            }
        }
    }
    out.push_str("</body>\n</html>\n");
    out
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// The Markdown subset the document uses: `code` and **bold**.
fn inline(s: &str) -> String {
    let mut out = String::new();
    let mut code = false;
    let mut bold = false;
    let text = escape(s);
    let mut rest = text.as_str();
    while !rest.is_empty() {
        if let Some(r) = rest.strip_prefix("**") {
            out.push_str(if bold { "</strong>" } else { "<strong>" });
            bold = !bold;
            rest = r;
        } else if let Some(r) = rest.strip_prefix('`') {
            out.push_str(if code { "</code>" } else { "<code>" });
            code = !code;
            rest = r;
        } else {
            let c = rest.chars().next().expect("non-empty");
            out.push(c);
            rest = &rest[c.len_utf8()..];
        }
    }
    out
}

fn windows_csv(a: &Analysis) -> String {
    let mut out =
        "window,start_s,end_s,duration_s,steady,gravity_x,gravity_y,gravity_z\n".to_string();
    for w in &a.windows {
        let _ = writeln!(
            out,
            "{},{:.4},{:.4},{:.4},{},{:.6},{:.6},{:.6}",
            w.index,
            w.start_s,
            w.end_s,
            w.duration_s,
            w.steady,
            w.gravity_device[0],
            w.gravity_device[1],
            w.gravity_device[2]
        );
    }
    out
}

fn resolution_csv(a: &Analysis) -> String {
    let Some(r) = &a.resolution else {
        return String::new();
    };
    let mut out = "tau_s".to_string();
    for (name, unit) in &r.channels {
        let _ = write!(out, ",{name}_{}", unit.replace('/', "_per_"));
    }
    out.push('\n');
    for row in &r.rows {
        let _ = write!(out, "{}", row.tau_s);
        for v in &row.adev {
            let _ = write!(out, ",{}", v.map_or(String::new(), |v| format!("{v:.6e}")));
        }
        out.push('\n');
    }
    out
}

// --- Plots -------------------------------------------------------------------

const W: f64 = 760.0;
const H: f64 = 380.0;
const LEFT: f64 = 70.0;
const RIGHT: f64 = 150.0;
const TOP: f64 = 36.0;
const BOTTOM: f64 = 48.0;
const COLORS: [&str; 8] = [
    "#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#e377c2", "#17becf",
];

struct Axis<'a> {
    label: &'a str,
    lo: f64,
    hi: f64,
    log: bool,
}

impl Axis<'_> {
    fn map(&self, v: f64, from: f64, to: f64) -> f64 {
        let (v, lo, hi) = if self.log {
            (v.log10(), self.lo.log10(), self.hi.log10())
        } else {
            (v, self.lo, self.hi)
        };
        from + (v - lo) / (hi - lo) * (to - from)
    }

    fn ticks(&self) -> Vec<f64> {
        if self.log {
            let (a, b) = (
                self.lo.log10().ceil() as i32,
                self.hi.log10().floor() as i32,
            );
            (a..=b).map(|e| 10f64.powi(e)).collect()
        } else {
            let step = nice_step((self.hi - self.lo) / 5.0);
            let first = (self.lo / step).ceil() as i64;
            let last = (self.hi / step).floor() as i64;
            (first..=last).map(|i| i as f64 * step).collect()
        }
    }
}

fn nice_step(raw: f64) -> f64 {
    let p = 10f64.powf(raw.log10().floor());
    let f = raw / p;
    p * if f < 1.5 {
        1.0
    } else if f < 3.5 {
        2.0
    } else if f < 7.5 {
        5.0
    } else {
        10.0
    }
}

fn plot(
    title: &str,
    x: Axis,
    y: Axis,
    series: &[(String, Vec<(f64, f64)>)],
    shaded: &[(f64, f64)],
    marks: &[(f64, String)],
) -> String {
    let px = |v: f64| x.map(v, LEFT, W - RIGHT);
    let py = |v: f64| y.map(v, H - BOTTOM, TOP);
    let mut s = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {W} {H}\" width=\"{W}\" height=\"{H}\" font-family=\"-apple-system, system-ui, sans-serif\" font-size=\"12\">\n<rect width=\"{W}\" height=\"{H}\" fill=\"#ffffff\"/>\n<text x=\"{}\" y=\"20\" font-size=\"14\" font-weight=\"600\">{}</text>\n",
        LEFT,
        escape(title)
    );
    for (a, b) in shaded {
        let (xa, xb) = (px(a.max(x.lo)), px(b.min(x.hi)));
        let _ = writeln!(
            s,
            "<rect x=\"{xa:.1}\" y=\"{TOP}\" width=\"{:.1}\" height=\"{:.1}\" fill=\"#2ca02c\" fill-opacity=\"0.12\"/>",
            (xb - xa).max(0.0),
            H - TOP - BOTTOM
        );
    }
    for t in x.ticks() {
        let _ = writeln!(
            s,
            "<line x1=\"{0:.1}\" y1=\"{TOP}\" x2=\"{0:.1}\" y2=\"{1}\" stroke=\"#e5e5ea\"/>\n<text x=\"{0:.1}\" y=\"{2}\" text-anchor=\"middle\">{3}</text>",
            px(t),
            H - BOTTOM,
            H - BOTTOM + 16.0,
            tick(t)
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
    for (t, label) in marks {
        if *t < x.lo || *t > x.hi {
            continue;
        }
        let _ = writeln!(
            s,
            "<line x1=\"{0:.1}\" y1=\"{TOP}\" x2=\"{0:.1}\" y2=\"{1}\" stroke=\"#86868b\" stroke-dasharray=\"3 3\"/>\n<text x=\"{2:.1}\" y=\"{3}\" font-size=\"10\" fill=\"#515154\">{4}</text>",
            px(*t),
            H - BOTTOM,
            px(*t) + 3.0,
            TOP + 12.0,
            escape(label)
        );
    }
    for (i, (name, points)) in series.iter().enumerate() {
        let color = COLORS[i % COLORS.len()];
        let path: Vec<String> = points
            .iter()
            .filter(|(a, b)| (!x.log || *a > 0.0) && (!y.log || *b > 0.0))
            .map(|&(a, b)| format!("{:.1},{:.1}", px(a), py(b.clamp(y.lo, y.hi))))
            .collect();
        if !path.is_empty() {
            let _ = writeln!(
                s,
                "<polyline fill=\"none\" stroke=\"{color}\" stroke-width=\"1.5\" points=\"{}\"/>",
                path.join(" ")
            );
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
            escape(name)
        );
    }
    s.push_str("</svg>\n");
    s
}

fn timeline_svg(a: &Analysis, data: &SessionData) -> String {
    let t0 = a.t0_phone_ns;
    // At most ~1500 points: the maximum rate in each bucket, so moves stay visible.
    let n = data.motion.len().max(1);
    let bucket = n.div_ceil(1500).max(1);
    let points: Vec<(f64, f64)> = data
        .motion
        .chunks(bucket)
        .map(|c| {
            let t = (c[0].t_ns - t0) as f64 / 1e9;
            let r = c
                .iter()
                .map(|m| crate::math::norm(m.rate).to_degrees())
                .fold(0.0, f64::max);
            (t, r)
        })
        .collect();
    let peak = points.iter().map(|p| p.1).fold(0.0, f64::max);
    let y_hi = (peak * 1.1).clamp(2.0 * a.config.still.max_rate_deg_s, 200.0);
    plot(
        "Fused rotation rate (still windows shaded)",
        Axis {
            label: "time (s)",
            lo: 0.0,
            hi: a.duration_s.max(1.0),
            log: false,
        },
        Axis {
            label: "°/s",
            lo: 0.0,
            hi: y_hi,
            log: false,
        },
        &[("|rotation rate|".into(), points)],
        &a.windows
            .iter()
            .map(|w| (w.start_s, w.end_s))
            .collect::<Vec<_>>(),
        &a.markers
            .iter()
            .map(|m| (m.t_s, m.label.clone()))
            .collect::<Vec<_>>(),
    )
}

fn adev_svg(a: &Analysis, channels: &[usize], title: &str, unit: &str) -> String {
    let r = a.resolution.as_ref().expect("resolution present");
    let series: Vec<(String, Vec<(f64, f64)>)> = channels
        .iter()
        .map(|&i| {
            (
                r.channels[i].0.to_string(),
                r.rows
                    .iter()
                    .filter_map(|row| row.adev[i].map(|v| (row.tau_s, v)))
                    .collect(),
            )
        })
        .collect();
    let values: Vec<f64> = series
        .iter()
        .flat_map(|(_, p)| p.iter().map(|q| q.1))
        .filter(|v| *v > 0.0)
        .collect();
    let taus: Vec<f64> = r.rows.iter().map(|row| row.tau_s).collect();
    let decade = |v: f64, up: bool| {
        let e = v.log10();
        10f64.powf(if up { e.ceil() } else { e.floor() })
    };
    let (ylo, yhi) = if values.is_empty() {
        (1e-4, 1.0)
    } else {
        (
            decade(values.iter().copied().fold(f64::MAX, f64::min), false),
            decade(values.iter().copied().fold(0.0, f64::max), true),
        )
    };
    let (xlo, xhi) = if taus.is_empty() {
        (0.01, 100.0)
    } else {
        (decade(taus[0], false), decade(taus[taus.len() - 1], true))
    };
    plot(
        title,
        Axis {
            label: "averaging time τ (s)",
            lo: xlo,
            hi: xhi,
            log: true,
        },
        Axis {
            label: unit,
            lo: ylo,
            hi: if yhi > ylo { yhi } else { ylo * 10.0 },
            log: true,
        },
        &series,
        &[],
        &[],
    )
}

// --- Formatting ------------------------------------------------------------

/// Four significant digits, switching to scientific notation for very small
/// or large magnitudes.
fn sig(v: f64) -> String {
    if v == 0.0 || !v.is_finite() {
        return format!("{v}");
    }
    let mag = v.abs().log10().floor() as i32;
    if !(-3..6).contains(&mag) {
        format!("{v:.3e}")
    } else {
        let decimals = (3 - mag).max(0) as usize;
        format!("{v:.decimals$}")
    }
}

/// Axis labels: `sig` without trailing zeros ("20", "0.01", "1e-4").
fn tick(v: f64) -> String {
    let s = sig(v);
    let (mantissa, exponent) = match s.split_once('e') {
        Some((m, e)) => (m.to_string(), format!("e{e}")),
        None => (s, String::new()),
    };
    let mantissa = if mantissa.contains('.') {
        mantissa
            .trim_end_matches('0')
            .trim_end_matches('.')
            .to_string()
    } else {
        mantissa
    };
    mantissa + &exponent
}

fn vec3(v: [f64; 3], digits: usize) -> String {
    format!(
        "({:+.digits$}, {:+.digits$}, {:+.digits$})",
        v[0], v[1], v[2]
    )
}

fn short(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}
