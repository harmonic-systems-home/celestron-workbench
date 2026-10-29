//! Clock model fits against simulated exchanges with known truth.

use cwb_protocol::Nanos;
use cwb_storage::clockfit::{Exchange, fit};

const PHONE_T0: Nanos = 512_000_000_000;
const OFFSET: Nanos = 3_217_000_000;
const MS: Nanos = 1_000_000;

/// Deterministic pseudo-random numbers in [0, 1).
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// The Mac clock that matches a phone running `drift_ppm` slow relative to it.
fn mac_at(phone_ns: Nanos, drift_ppm: f64) -> Nanos {
    phone_ns + OFFSET + ((phone_ns - PHONE_T0) as f64 * drift_ppm / 1e6).round() as Nanos
}

/// Exchanges every `every_s` seconds. `outbound` and `inbound` give each
/// exchange's one-way delays; turnaround on the Mac is 50 µs.
fn exchanges(
    count: u64,
    every_s: f64,
    drift_ppm: f64,
    mut delays: impl FnMut(u64) -> (Nanos, Nanos),
) -> Vec<Exchange> {
    (0..count)
        .map(|i| {
            let (outbound, inbound) = delays(i);
            let t1 = PHONE_T0 + (i as f64 * every_s * 1e9) as Nanos;
            let arrive = t1 + outbound;
            let leave = arrive + 50_000;
            let t4 = leave + inbound;
            Exchange {
                index: i,
                phone_send_ns: t1,
                mac_receive_ns: mac_at(arrive, drift_ppm),
                mac_send_ns: mac_at(leave, drift_ppm),
                phone_receive_ns: t4,
            }
        })
        .collect()
}

#[test]
fn recovers_offset_and_drift_through_wifi_like_delays() {
    let mut rng = Lcg(7);
    // 2-4 ms each way, and every other exchange stalls 5-300 ms in one direction.
    let list = exchanges(300, 2.0, 20.0, |i| {
        let out = 2 * MS + (rng.next() * 2e6) as Nanos;
        let back = 2 * MS + (rng.next() * 2e6) as Nanos;
        let stall = 5 * MS + (rng.next() * 295e6) as Nanos;
        match i % 4 {
            1 => (out + stall, back),
            3 => (out, back + stall),
            _ => (out, back),
        }
    });
    let model = fit("mac", Some("phone"), &list).unwrap();
    assert!(model.drift_fitted);
    assert!(
        (model.drift_ppb / 1e3 - 20.0).abs() < 0.1,
        "drift {} ppm",
        model.drift_ppb / 1e3
    );
    for &phone in &[
        PHONE_T0,
        PHONE_T0 + 300_000_000_000,
        PHONE_T0 + 598_000_000_000,
    ] {
        let error = model.to_mac_ns(phone) - mac_at(phone, 20.0);
        assert!(
            error.abs() <= model.uncertainty_ns,
            "error {error} ns exceeds uncertainty {} ns",
            model.uncertainty_ns
        );
    }
    // The stalled exchanges were left out, and the bound comes from the kept ones.
    assert!(model.uncertainty_ns >= model.round_trip_median_ns / 2);
    assert!(model.used <= 150);
    assert!(model.round_trip_median_ns < 10 * MS);
}

#[test]
fn a_constant_one_way_delay_stays_within_the_reported_uncertainty() {
    // No exchange can see this asymmetry: the estimate is off by half the
    // difference, 1.5 ms, and the reported uncertainty must cover it.
    let list = exchanges(60, 1.0, 0.0, |_| (4 * MS, MS));
    let model = fit("mac", None, &list).unwrap();
    let error = model.to_mac_ns(PHONE_T0 + 30_000_000_000) - mac_at(PHONE_T0 + 30_000_000_000, 0.0);
    assert_eq!(error, 1_500_000);
    assert!(model.uncertainty_ns >= error.abs());
    assert!(model.uncertainty_ns <= 3 * MS);
}

#[test]
fn drift_is_not_fitted_from_a_short_span() {
    let list = exchanges(10, 2.0, 50.0, |_| (MS, MS));
    let model = fit("mac", None, &list).unwrap();
    assert!(!model.drift_fitted);
    assert_eq!(model.drift_ppb, 0.0);
    assert_eq!(model.valid_from_phone_ns, PHONE_T0);
    assert_eq!(model.exchanges, 10);
}

#[test]
fn one_exchange_gives_an_offset_and_its_round_trip_bound() {
    let list = exchanges(1, 1.0, 0.0, |_| (3 * MS, 3 * MS));
    let model = fit("mac", None, &list).unwrap();
    assert_eq!(model.offset_ns, OFFSET);
    assert_eq!(model.round_trip_min_ns, 6 * MS);
    assert_eq!(model.uncertainty_ns, 3 * MS);
    assert!(!model.resolves(3 * MS));
    assert!(model.resolves(-4 * MS));
    assert!(fit("mac", None, &[]).is_none());
}
