import Foundation

extension Quaternion {
    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    public var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    /// Unit quaternion in the same direction, or nil if the norm is zero or not finite.
    public func normalized() -> Quaternion? {
        let n = norm
        guard n > 0, n.isFinite else { return nil }
        return Quaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public var conjugate: Quaternion { Quaternion(w: w, x: -x, y: -y, z: -z) }

    /// Hamilton product `self * other`.
    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    /// Rotation angle in radians (0...π) between two attitudes. `q` and `-q`
    /// are the same rotation, so the sign of either input doesn't matter.
    /// Inputs are normalized first; returns nil if either can't be.
    public func angle(to other: Quaternion) -> Double? {
        guard let a = normalized(), let b = other.normalized() else { return nil }
        let dot = abs(a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z)
        return 2 * acos(min(1, dot))
    }
}
