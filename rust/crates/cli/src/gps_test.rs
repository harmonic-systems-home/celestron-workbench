//! `cwb celestron gps-test` (ADR 0020): speak as the GPS through the
//! mount's Wi-Fi and record what happens. The mount's address is never
//! printed or written to the trace (docs/privacy.md).

use std::{
    fs::{self, File},
    io::{BufWriter, IsTerminal, Write},
    path::Path,
    process::ExitCode,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use cwb_aux_gps::{
    gps::{self, Clock, DECOY, Utc},
    link::{FakeLink, Link, TcpLink},
    packet::Packet,
    run::{Event, Plan, Summary, run},
};
use serde_json::json;

#[derive(Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum GpsTime {
    /// 2030-01-01 12:00:00 UTC, so a change on the hand controller shows.
    Decoy,
    /// This Mac's clock.
    Now,
}

pub fn parse_hand_controller(s: &str) -> Result<u8, String> {
    let v = u8::from_str_radix(s.trim_start_matches("0x"), 16)
        .map_err(|_| format!("{s}: give a hex address such as 0e"))?;
    if gps::HAND_CONTROLLERS.contains(&v) {
        Ok(v)
    } else {
        Err(format!("{s}: hand controllers are 04, 0d and 0e"))
    }
}

pub struct Options<'a> {
    pub host: &'a str,
    pub simulate: bool,
    pub time: GpsTime,
    pub seconds: f64,
    pub push_every: f64,
    pub hand_controller: u8,
    pub out: &'a Path,
    pub yes: bool,
}

pub fn gps_test(o: Options) -> Result<ExitCode> {
    let plan = Plan {
        hand_controller: o.hand_controller,
        clock: match o.time {
            GpsTime::Decoy => Clock::Fixed(Utc::DECOY),
            GpsTime::Now => Clock::Now,
        },
        push_every: (o.push_every > 0.0).then(|| Duration::from_secs_f64(o.push_every)),
        gap: Duration::from_millis(50),
        duration: Duration::from_secs_f64(o.seconds),
    };
    let time = match o.time {
        GpsTime::Decoy => "2030-01-01 12:00:00 UTC (decoy)".to_owned(),
        GpsTime::Now => "this Mac's clock, UTC".to_owned(),
    };
    println!(
        "As the GPS (0xB0), to the hand controller ({:#04x}), for {:.0} s:",
        o.hand_controller, o.seconds
    );
    println!("  time:     {time}");
    println!(
        "  location: {:.4}° N, {:.4}° W (decoy: Royal Observatory, Greenwich)",
        DECOY.latitude, -DECOY.longitude
    );
    match plan.push_every {
        Some(d) => println!(
            "  pushes the GPS replies every {:.0} s, and answers any GPS request",
            d.as_secs_f64()
        ),
        None => println!("  only answers GPS requests"),
    }
    println!("No motion: only GPS replies can be sent. Unplug a real GPS first.");
    if !o.yes && !o.simulate {
        if !std::io::stdin().is_terminal() {
            anyhow::bail!("no terminal to confirm on: pass --yes to proceed");
        }
        print!("Connect to the mount's Wi-Fi and start? [y/N] ");
        std::io::stdout().flush()?;
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !answer.trim().eq_ignore_ascii_case("y") {
            println!("nothing sent");
            return Ok(ExitCode::FAILURE);
        }
    }

    let started = cwb_storage::clock::utc_now();
    let dir = o.out.join(started.replace(':', "-"));
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let trace_path = dir.join("trace.ndjson");
    let mut trace = BufWriter::new(File::create(&trace_path)?);
    writeln!(
        trace,
        "{}",
        json!({
            "event": "start", "utc": started, "simulated": o.simulate,
            "hand_controller": o.hand_controller, "time": time,
            "push_every_s": o.push_every, "seconds": o.seconds,
        })
    )?;

    let summary = if o.simulate {
        let mut link = FakeLink::default();
        for id in [gps::LINKED, gps::TIME_VALID, gps::GET_YEAR, gps::GET_TIME] {
            let ask = Packet {
                src: o.hand_controller,
                dst: gps::GPS,
                id,
                data: vec![],
            };
            link.incoming.push_back(ask.encode());
        }
        go(&mut link, &plan, &mut trace)?
    } else {
        eprintln!("connecting to the mount's Wi-Fi…");
        let mut link = TcpLink::connect(o.host).context("connecting to the mount's Wi-Fi")?;
        go(&mut link, &plan, &mut trace)?
    };

    writeln!(
        trace,
        "{}",
        json!({
            "event": "end", "utc": cwb_storage::clock::utc_now(),
            "pushed": summary.pushed, "echoed": summary.echoed,
            "answered": summary.answered,
            "from_hand_controller": summary.from_hand_controller,
            "other_gps": summary.other_gps,
            "gps_requests": summary.gps_requests.iter()
                .map(|((src, id), n)| json!({"from": src, "id": id, "name": gps::name(*id), "count": n}))
                .collect::<Vec<_>>(),
        })
    )?;
    trace.flush()?;

    println!();
    println!("pushed {}, echoed back {}", summary.pushed, summary.echoed);
    println!(
        "packets from the hand controller: {}",
        summary.from_hand_controller
    );
    if summary.gps_requests.is_empty() {
        println!("GPS requests heard: none");
    } else {
        for ((src, id), n) in &summary.gps_requests {
            println!("GPS request from {src:#04x}: {} ×{n}", gps::name(*id));
        }
        println!("answered {}", summary.answered);
    }
    if summary.other_gps > 0 {
        println!(
            "warning: {} packets from another GPS: unplug it and run again",
            summary.other_gps
        );
    }
    println!("Now check the hand controller's time and site, and the AUX Listener's log.");
    println!("trace: {}", trace_path.display());
    Ok(ExitCode::SUCCESS)
}

fn go<L: Link>(link: &mut L, plan: &Plan, trace: &mut impl Write) -> Result<Summary> {
    let start = Instant::now();
    let mut write_err = None;
    let summary = run(
        link,
        plan,
        &mut || start.elapsed(),
        &mut || Utc::from_timestamp(jiff::Timestamp::now()),
        &mut |e| {
            let t_ms = start.elapsed().as_millis() as u64;
            let (kind, p, extra) = match e {
                Event::Pushed(p) => ("pushed", p, None),
                Event::Echo(p) => ("echo", p, None),
                Event::Heard(p) => ("heard", p, None),
                Event::Answered { request, reply } => (
                    "gps_request",
                    request,
                    Some(reply.as_ref().map(Packet::hex)),
                ),
            };
            let line = json!({
                "event": kind, "t_ms": t_ms, "src": p.src, "dst": p.dst,
                "id": p.id, "hex": p.hex(), "reply": extra,
            });
            if let Err(err) = writeln!(trace, "{line}") {
                write_err.get_or_insert(err);
            }
            match e {
                Event::Pushed(_) | Event::Echo(_) => {}
                Event::Answered { request, reply } => println!(
                    "{:>6.1} s  GPS request {} from {:#04x}{}",
                    t_ms as f64 / 1000.0,
                    gps::name(request.id),
                    request.src,
                    if reply.is_some() {
                        ", answered"
                    } else {
                        ", not answered"
                    }
                ),
                Event::Heard(p) if p.src == plan.hand_controller => println!(
                    "{:>6.1} s  hand controller → {:#04x}: {}",
                    t_ms as f64 / 1000.0,
                    p.dst,
                    p.hex()
                ),
                Event::Heard(_) => {}
            }
        },
    )?;
    if let Some(err) = write_err {
        return Err(err).context("writing the trace");
    }
    Ok(summary)
}
