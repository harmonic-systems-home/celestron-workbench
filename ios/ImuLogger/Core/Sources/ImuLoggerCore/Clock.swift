import Foundation

/// The phone's monotonic clock domain (ADR 0001).
public enum PhoneClock {
    /// Nanoseconds since boot, not counting sleep. Assumed to match the clock
    /// behind Core Motion timestamps (docs/assumptions.md, P1).
    public static func nowNs() -> Nanos {
        Nanos(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// Converts a Core Motion timestamp (seconds since boot) to integer nanoseconds.
    public static func nanos(fromSeconds seconds: TimeInterval) -> Nanos {
        Nanos((seconds * 1e9).rounded())
    }

    /// Identifies the current boot, so a reboot shows up as a new clock domain.
    /// Uses the kernel's boot session UUID; falls back to a per-launch UUID,
    /// which is conservative (treats each launch as a new domain).
    public static let bootId: String = {
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 {
                let value = String(
                    decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
                if UUID(uuidString: value) != nil { return value.lowercased() }
            }
        }
        return UUID().uuidString.lowercased()
    }()
}

extension Vec3 {
    /// Converts a Core Motion acceleration in g to m/s² (ADR 0002).
    public static func metersPerSecondSquared(fromG x: Double, _ y: Double, _ z: Double) -> Vec3 {
        Vec3(x * standardGravity, y * standardGravity, z * standardGravity)
    }

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}
