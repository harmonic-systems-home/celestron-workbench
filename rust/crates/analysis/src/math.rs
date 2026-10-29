//! Quaternions, descriptive statistics and Allan deviation.

use serde::Serialize;

pub type Quat = [f64; 4];

pub fn qmul(a: Quat, b: Quat) -> Quat {
    let [w1, x1, y1, z1] = a;
    let [w2, x2, y2, z2] = b;
    [
        w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
        w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
        w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
        w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
    ]
}

pub fn qconj(q: Quat) -> Quat {
    [q[0], -q[1], -q[2], -q[3]]
}

pub fn qnorm(q: Quat) -> Quat {
    let n = q.iter().map(|x| x * x).sum::<f64>().sqrt();
    q.map(|x| x / n)
}

/// q and −q are the same rotation; this picks the one with w ≥ 0.
pub fn qcanonical(q: Quat) -> Quat {
    if q[0] < 0.0 { q.map(|x| -x) } else { q }
}

/// Rotation angle (rad, 0..π) and unit axis of a quaternion.
pub fn angle_axis(q: Quat) -> (f64, [f64; 3]) {
    let q = qcanonical(qnorm(q));
    let s = (q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).sqrt();
    let angle = 2.0 * s.atan2(q[0]);
    if s < 1e-15 {
        (0.0, [0.0, 0.0, 1.0])
    } else {
        (angle, [q[1] / s, q[2] / s, q[3] / s])
    }
}

/// Angle (rad, −π..π) of the twist about the reference frame's vertical
/// in a reference-frame rotation `q` (swing-twist decomposition).
pub fn twist_about_z(q: Quat) -> f64 {
    let q = qcanonical(q);
    let angle = 2.0 * q[3].atan2(q[0]);
    wrap(angle)
}

/// Wraps an angle to (−π, π].
pub fn wrap(a: f64) -> f64 {
    let tau = std::f64::consts::TAU;
    let w = a - tau * (a / tau).round();
    if w <= -std::f64::consts::PI {
        w + tau
    } else {
        w
    }
}

/// The average rotation of nearby quaternions: sign-aligned to the first,
/// summed and normalized. Accurate for the small spread of a still window.
pub fn qmean(qs: impl Iterator<Item = Quat>) -> Option<Quat> {
    let mut sum = [0.0; 4];
    let mut first: Option<Quat> = None;
    for q in qs {
        let f = *first.get_or_insert(q);
        let dot: f64 = (0..4).map(|i| f[i] * q[i]).sum();
        let s = if dot < 0.0 { -1.0 } else { 1.0 };
        for i in 0..4 {
            sum[i] += s * q[i];
        }
    }
    first.map(|_| qnorm(sum))
}

/// Rotates a vector by a unit quaternion.
pub fn rotate(q: Quat, v: [f64; 3]) -> [f64; 3] {
    let p = qmul(qmul(q, [0.0, v[0], v[1], v[2]]), qconj(q));
    [p[1], p[2], p[3]]
}

pub fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

pub fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

pub fn norm(a: [f64; 3]) -> f64 {
    dot(a, a).sqrt()
}

pub fn unit(a: [f64; 3]) -> [f64; 3] {
    let n = norm(a);
    a.map(|x| x / n)
}

/// Removes ±2π jumps from a sequence of wrapped angles.
pub fn unwrap(angles: &[f64]) -> Vec<f64> {
    let mut out = Vec::with_capacity(angles.len());
    let mut offset = 0.0;
    let mut prev: Option<f64> = None;
    for &a in angles {
        if let Some(p) = prev {
            offset += wrap(a - p) - (a - p);
        }
        out.push(a + offset);
        prev = Some(a);
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Summary {
    pub n: usize,
    pub mean: f64,
    pub sd: f64,
    pub rms: f64,
    /// Median absolute deviation scaled by 1.4826 (≈ sd for normal data).
    pub mad: f64,
    pub p05: f64,
    pub p95: f64,
}

pub fn summarize(x: &[f64]) -> Option<Summary> {
    if x.is_empty() {
        return None;
    }
    let n = x.len() as f64;
    let mean = x.iter().sum::<f64>() / n;
    let var = x.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0).max(1.0);
    let rms = (x.iter().map(|v| v * v).sum::<f64>() / n).sqrt();
    let mut sorted = x.to_vec();
    sorted.sort_by(f64::total_cmp);
    let median = percentile(&sorted, 50.0);
    let mut dev: Vec<f64> = x.iter().map(|v| (v - median).abs()).collect();
    dev.sort_by(f64::total_cmp);
    Some(Summary {
        n: x.len(),
        mean,
        sd: var.sqrt(),
        rms,
        mad: 1.4826 * percentile(&dev, 50.0),
        p05: percentile(&sorted, 5.0),
        p95: percentile(&sorted, 95.0),
    })
}

/// Linear-interpolated percentile of sorted data.
pub fn percentile(sorted: &[f64], p: f64) -> f64 {
    let pos = p / 100.0 * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
}

/// Least-squares slope of y against x.
pub fn slope(x: &[f64], y: &[f64]) -> Option<f64> {
    let n = x.len() as f64;
    if x.len() < 2 {
        return None;
    }
    let mx = x.iter().sum::<f64>() / n;
    let my = y.iter().sum::<f64>() / n;
    let sxx: f64 = x.iter().map(|v| (v - mx).powi(2)).sum();
    (sxx > 0.0).then(|| {
        x.iter()
            .zip(y)
            .map(|(a, b)| (a - mx) * (b - my))
            .sum::<f64>()
            / sxx
    })
}

/// Overlapping Allan deviation of evenly spaced values averaged over `m`
/// samples: the standard deviation of the difference between adjacent
/// m-sample averages, divided by √2. For rate data it is the usual Allan
/// deviation; for angle data it is the noise in comparing two still
/// windows of that length.
pub fn allan_deviation(x: &[f64], m: usize) -> Option<f64> {
    let n = x.len();
    if m == 0 || n < 2 * m + 1 {
        return None;
    }
    let mut cum = Vec::with_capacity(n + 1);
    cum.push(0.0);
    for v in x {
        cum.push(cum.last().copied().unwrap_or(0.0) + v);
    }
    let avg = |k: usize| (cum[k + m] - cum[k]) / m as f64;
    let count = n - 2 * m + 1;
    let sum: f64 = (0..count).map(|k| (avg(k + m) - avg(k)).powi(2)).sum();
    Some((sum / (2.0 * count as f64)).sqrt())
}
