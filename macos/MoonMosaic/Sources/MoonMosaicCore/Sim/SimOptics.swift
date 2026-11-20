import Foundation

/// The simulated telescope and camera (ADR 0022 amendment 7): change the
/// setup to simulate another camera, a Barlow or reducer, or the scope
/// without its star diagonal.
public struct SimOptics: Sendable, Equatable, Codable {
    /// The telescope's native focal length.
    public var focalLengthMm: Double
    /// A Barlow (above 1) or a reducer (below 1); 1 for neither.
    public var multiplier: Double
    /// A star diagonal mirrors the image left to right.
    public var diagonal: Bool
    /// How far the camera is turned in the focuser, degrees: its rotation
    /// against azimuth and altitude at the eyepiece end. (The field rotates
    /// further with the Moon's own orientation on the sky.)
    public var cameraRotationDeg: Double
    public var sensor: SimSensor

    public init(
        focalLengthMm: Double, multiplier: Double = 1, diagonal: Bool = true,
        cameraRotationDeg: Double = 0, sensor: SimSensor
    ) {
        self.focalLengthMm = focalLengthMm
        self.multiplier = multiplier
        self.diagonal = diagonal
        self.cameraRotationDeg = cameraRotationDeg
        self.sensor = sensor
    }

    /// Arcseconds per pixel at best focus.
    public var arcsecPerPixel: Double {
        206.265 * sensor.pixelSizeUm / (focalLengthMm * multiplier)
    }

    /// The field, arcminutes across and down.
    public var fieldArcmin: (width: Double, height: Double) {
        (
            Double(sensor.width) * arcsecPerPixel / 60,
            Double(sensor.height) * arcsecPerPixel / 60
        )
    }

    /// An 8″ SCT (2032 mm) with the diagonal and a ZWO ASI662MC.
    public static let sct8 = SimOptics(focalLengthMm: 2032, sensor: .asi662mc)
}

public struct SimSensor: Sendable, Equatable, Codable {
    public var name: String
    public var width: Int
    public var height: Int
    public var pixelSizeUm: Double
    public var isColor: Bool
    /// ZWO's ASI_BAYER_PATTERN: 0 RG, 1 BG, 2 GR, 3 GB.
    public var bayerPattern: Int
    /// Frames per second when streaming video.
    public var fps: Double

    public init(
        name: String, width: Int, height: Int, pixelSizeUm: Double, isColor: Bool,
        bayerPattern: Int = 0, fps: Double
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.pixelSizeUm = pixelSizeUm
        self.isColor = isColor
        self.bayerPattern = bayerPattern
        self.fps = fps
    }

    public static let asi662mc = SimSensor(
        name: "Simulated ASI662MC", width: 1920, height: 1080, pixelSizeUm: 2.9, isColor: true,
        fps: 60)
    /// A wider field: larger sensor, larger pixels.
    public static let wide = SimSensor(
        name: "Simulated wide camera", width: 3096, height: 2080, pixelSizeUm: 2.4,
        isColor: true, fps: 30)
    /// A small mono camera, for fast tests.
    public static let testMono = SimSensor(
        name: "Simulated test camera", width: 640, height: 360, pixelSizeUm: 2.9, isColor: false,
        fps: 100)
}
