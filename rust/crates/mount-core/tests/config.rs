//! The safety configuration refuses settings that would blind an interlock.

use cwb_mount_core::{Controller, SafetyConfig};

#[test]
fn the_default_configuration_is_sound() {
    assert!(SafetyConfig::default().problems().is_empty());
    assert!(Controller::new(SafetyConfig::default()).is_ok());
}

#[test]
fn unsound_configurations_are_refused() {
    let cases: Vec<(&str, SafetyConfig)> = vec![
        (
            "direction can't be confirmed",
            SafetyConfig {
                min_rate_deg_s: 0.1,
                ..SafetyConfig::default()
            },
        ),
        (
            "a stall could go unnoticed",
            SafetyConfig {
                max_duration_ms: 500,
                ..SafetyConfig::default()
            },
        ),
        (
            "still_deg_s must be below motion_deg_s",
            SafetyConfig {
                still_deg_s: 0.2,
                ..SafetyConfig::default()
            },
        ),
        (
            "envelope is empty",
            SafetyConfig {
                min_altitude_deg: 60.0,
                max_altitude_deg: 50.0,
                ..SafetyConfig::default()
            },
        ),
        (
            "imu_max_age_ms must be positive",
            SafetyConfig {
                imu_max_age_ms: 0,
                ..SafetyConfig::default()
            },
        ),
        (
            "max_rate_deg_s must be positive",
            SafetyConfig {
                max_rate_deg_s: f64::NAN,
                ..SafetyConfig::default()
            },
        ),
    ];
    for (expected, config) in cases {
        let problems = config.problems();
        assert!(
            problems.iter().any(|p| p.contains(expected)),
            "expected {expected:?}, got {problems:?}"
        );
        assert!(Controller::new(config).is_err());
    }
}
