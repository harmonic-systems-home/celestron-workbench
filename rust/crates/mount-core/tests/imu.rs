//! The phone-to-mount-axis conversion against a phone placed on a simulated
//! tube at known angles, with its top toward the sky end and any roll.

use cwb_mount_core::imu::AxisMapper;

const G: f64 = 9.80665;

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// World frame: x north, y west, z up (right-handed). The phone's y axis
/// lies along the tube, rolled `roll_deg` about it. Returns the phone axes
/// in world terms.
fn phone_axes(azimuth_deg: f64, altitude_deg: f64, roll_deg: f64) -> [[f64; 3]; 3] {
    let (az, alt, roll) = (
        azimuth_deg.to_radians(),
        altitude_deg.to_radians(),
        roll_deg.to_radians(),
    );
    // Compass azimuth runs clockwise from north seen from above: toward east, -y.
    let tube = [alt.cos() * az.cos(), -alt.cos() * az.sin(), alt.sin()];
    let side = cross(tube, [0.0, 0.0, 1.0]);
    let n = dot(side, side).sqrt();
    let side = [side[0] / n, side[1] / n, side[2] / n];
    let lift = cross(side, tube);
    let x = [
        side[0] * roll.cos() + lift[0] * roll.sin(),
        side[1] * roll.cos() + lift[1] * roll.sin(),
        side[2] * roll.cos() + lift[2] * roll.sin(),
    ];
    let z = cross(x, tube);
    [x, tube, z]
}

/// A world vector in the phone's body frame.
fn body(axes: [[f64; 3]; 3], v: [f64; 3]) -> [f64; 3] {
    [dot(axes[0], v), dot(axes[1], v), dot(axes[2], v)]
}

fn mapper() -> AxisMapper {
    AxisMapper::new([0.0, 1.0, 0.0]).unwrap()
}

#[test]
fn altitude_comes_from_the_tube_tilt_whatever_the_roll() {
    for roll in [0.0, 37.0, 90.0, 180.0, -120.0] {
        let axes = phone_axes(123.0, 30.0, roll);
        let o = mapper()
            .observe(0, [0.0; 3], body(axes, [0.0, 0.0, -G]))
            .unwrap();
        assert!((o.altitude_deg - 30.0).abs() < 1e-9, "roll {roll}: {o:?}");
        assert!(o.rate_deg_s.iter().all(|r| r.abs() < 1e-12));
    }
}

#[test]
fn azimuth_rate_is_clockwise_from_above_and_altitude_is_untouched() {
    // 0.1 °/s clockwise seen from above is a rotation about world down.
    let rate = 0.1f64.to_radians();
    for (alt, roll) in [(10.0, 0.0), (45.0, 70.0), (80.0, -30.0)] {
        let axes = phone_axes(200.0, alt, roll);
        let o = mapper()
            .observe(0, body(axes, [0.0, 0.0, -rate]), body(axes, [0.0, 0.0, -G]))
            .unwrap();
        assert!((o.rate_deg_s[0] - 0.1).abs() < 1e-9, "{o:?}");
        assert!(o.rate_deg_s[1].abs() < 1e-9, "{o:?}");
    }
}

#[test]
fn altitude_rate_is_positive_as_the_tube_rises() {
    let rate = 0.25f64.to_radians();
    for roll in [0.0, 45.0, 135.0] {
        let axes = phone_axes(80.0, 40.0, roll);
        // The tube rises by rotating about tube × up.
        let k = cross(axes[1], [0.0, 0.0, 1.0]);
        let n = dot(k, k).sqrt();
        let omega = [k[0] / n * rate, k[1] / n * rate, k[2] / n * rate];
        let o = mapper()
            .observe(0, body(axes, omega), body(axes, [0.0, 0.0, -G]))
            .unwrap();
        assert!((o.rate_deg_s[1] - 0.25).abs() < 1e-9, "{o:?}");
        assert!(o.rate_deg_s[0].abs() < 1e-9, "{o:?}");
    }
}

#[test]
fn a_tube_near_vertical_or_missing_gravity_gives_no_observation() {
    let axes = phone_axes(0.0, 89.0, 0.0);
    assert!(
        mapper()
            .observe(0, [0.0; 3], body(axes, [0.0, 0.0, -G]))
            .is_none()
    );
    assert!(mapper().observe(0, [0.0; 3], [0.0, 0.0, 0.0]).is_none());
    assert!(AxisMapper::new([0.0; 3]).is_err());
}
