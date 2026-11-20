import Foundation

/// The flow's aimed moves (ADR 0022 amendment 7, steps 4, 7 and 8): to the
/// bright limb for judging exposure, to the terminator for fine focus, and
/// the Recheck after focusing.
extension MosaicSession {
    public enum Feature: String, Sendable {
        /// The bright limb about a quarter of the frame in from one edge, the
        /// rest of the frame Moon: for judging exposure (Auto-set).
        case limb
        /// Where the terminator crosses the axis through the bright limb:
        /// long shadows, the best detail for focusing.
        case terminator
    }

    /// The sky offset from the Moon's centre that puts `feature` mid-frame.
    public func featureOffset(_ feature: Feature) throws -> SkyOffset {
        guard let calibration, let here else {
            throw MosaicError(description: "Orient the camera and the Moon first.")
        }
        let phase = Ephemeris.phase(at: clock(), from: settings.site)
        let r = here.moon.diameterDeg / 2 * 3600
        let (lx, ly) = phase.brightLimb
        switch feature {
        case .terminator:
            // a = −cos(phase angle) along the bright limb's axis.
            let a = -cos(phase.phaseAngleDeg * .pi / 180) * r
            return SkyOffset(x: a * lx, y: a * ly)
        case .limb:
            // How far the frame reaches from its centre along the limb's
            // direction (in the image), then the limb at a quarter of the
            // frame from the edge: half that reach from the centre.
            let u = calibration.image(for: SkyOffset(x: lx, y: ly))
            let n = max(hypot(u.x, u.y), 1e-9)
            let (ux, uy) = (abs(u.x / n), abs(u.y / n))
            let reachPx = min(
                ux > 1e-6 ? Double(camera.info.width) / 2 / ux : .infinity,
                uy > 1e-6 ? Double(camera.info.height) / 2 / uy : .infinity)
            let d = r - 0.5 * reachPx * calibration.arcsecPerPixel
            return SkyOffset(x: d * lx, y: d * ly)
        }
    }

    /// Aims `feature` mid-frame (then the caller tracks on).
    public func goTo(_ feature: Feature) async throws {
        let o = try featureOffset(feature)
        try await armForStep()
        defer { endStep() }
        try await goToSky(o)
        onEvent(
            .message(
                String(
                    format: "At the %@: %.0f″, %.0f″ from the Moon's centre.", feature == .limb ? "bright limb" : "terminator",
                    o.x, o.y)))
    }

    /// Recheck (step 8): an SCT focuses by moving its main mirror, which
    /// changes the scale and shifts the image. A drift re-measures the scale
    /// (Orient Camera), then the survey re-measures the centre (Orient Moon).
    public func recheck() async throws {
        let before = calibration
        try await orientCamera()
        let fit = try await findCentre()
        if let before, let after = calibration {
            onEvent(
                .message(
                    String(
                        format: "Recheck: scale %.4f → %.4f″ per pixel (%+.2f%%); turned %.1f° → %.1f°; centre moved %.0f″.",
                        before.arcsecPerPixel, after.arcsecPerPixel, (after.arcsecPerPixel / before.arcsecPerPixel - 1) * 100,
                        before.rotationDeg, after.rotationDeg, hypot(fit.centre.x, fit.centre.y))))
        }
    }
}
