import CoreMotion
import ImuLoggerCore

/// Core Motion acquisition. Callbacks only convert values and hand them to the
/// bounded `AcquisitionBuffer`; everything else happens on the pipeline queue.
final class MotionSource: @unchecked Sendable {
    struct Configuration: Sendable {
        var interval: TimeInterval
        var referenceFrame: AttitudeReferenceFrame
        var streams: Set<SensorStream>
    }

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "cwb.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    // MARK: Capability discovery

    static func availability() -> SensorAvailability {
        let manager = CMMotionManager()
        return SensorAvailability(
            deviceMotion: manager.isDeviceMotionAvailable,
            gyro: manager.isGyroAvailable,
            accel: manager.isAccelerometerAvailable,
            magnetometer: manager.isMagnetometerAvailable)
    }

    /// Reference frames this device supports. True north is never offered:
    /// it needs location services, and the observing site stays private.
    static func availableFrames() -> [AttitudeReferenceFrame] {
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        return [
            .xArbitraryZVertical, .xArbitraryCorrectedZVertical, .xMagneticNorthZVertical,
        ]
        .filter { available.contains($0.coreMotion) }
    }

    // MARK: Acquisition

    func start(
        _ configuration: Configuration, into buffer: AcquisitionBuffer,
        onError: @escaping @Sendable (SensorStream, Error) -> Void
    ) {
        let interval = configuration.interval
        if configuration.streams.contains(.deviceMotion), manager.isDeviceMotionAvailable {
            let usesMagnetometer = configuration.referenceFrame.usesMagnetometer
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(
                using: configuration.referenceFrame.coreMotion, to: queue
            ) { motion, error in
                guard let motion else {
                    if let error { onError(.deviceMotion, error) }
                    return
                }
                let tNs = PhoneClock.nanos(fromSeconds: motion.timestamp)
                let q = motion.attitude.quaternion
                let r = motion.rotationRate
                let g = motion.gravity
                let a = motion.userAcceleration
                let field = motion.magneticField
                let sample = DeviceMotionSample(
                    seq: 0, tNs: tNs, attitude: Quaternion(w: q.w, x: q.x, y: q.y, z: q.z),
                    rotationRate: Vec3(r.x, r.y, r.z),
                    gravity: .metersPerSecondSquared(fromG: g.x, g.y, g.z),
                    userAccel: .metersPerSecondSquared(fromG: a.x, a.y, a.z),
                    magneticFieldUt: usesMagnetometer
                        ? Vec3(field.field.x, field.field.y, field.field.z) : nil,
                    magneticAccuracy: usesMagnetometer ? MagneticAccuracy(field.accuracy) : nil)
                buffer.offer(stream: .deviceMotion) { seq in
                    var numbered = sample
                    numbered.seq = seq
                    return .deviceMotion(numbered)
                }
            }
        }
        if configuration.streams.contains(.gyro), manager.isGyroAvailable {
            manager.gyroUpdateInterval = interval
            manager.startGyroUpdates(to: queue) { data, error in
                guard let data else {
                    if let error { onError(.gyro, error) }
                    return
                }
                let tNs = PhoneClock.nanos(fromSeconds: data.timestamp)
                let r = data.rotationRate
                buffer.offer(stream: .gyro) { seq in
                    .gyro(GyroSample(seq: seq, tNs: tNs, rotationRate: Vec3(r.x, r.y, r.z)))
                }
            }
        }
        if configuration.streams.contains(.accel), manager.isAccelerometerAvailable {
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: queue) { data, error in
                guard let data else {
                    if let error { onError(.accel, error) }
                    return
                }
                let tNs = PhoneClock.nanos(fromSeconds: data.timestamp)
                let accel = Vec3.metersPerSecondSquared(
                    fromG: data.acceleration.x, data.acceleration.y, data.acceleration.z)
                buffer.offer(stream: .accel) { seq in
                    .accel(AccelSample(seq: seq, tNs: tNs, accel: accel))
                }
            }
        }
        if configuration.streams.contains(.magnetometer), manager.isMagnetometerAvailable {
            manager.magnetometerUpdateInterval = interval
            manager.startMagnetometerUpdates(to: queue) { data, error in
                guard let data else {
                    if let error { onError(.magnetometer, error) }
                    return
                }
                let tNs = PhoneClock.nanos(fromSeconds: data.timestamp)
                let f = data.magneticField
                buffer.offer(stream: .magnetometer) { seq in
                    .magnetometer(
                        MagnetometerSample(seq: seq, tNs: tNs, magneticFieldUt: Vec3(f.x, f.y, f.z))
                    )
                }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        manager.stopGyroUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopMagnetometerUpdates()
        queue.waitUntilAllOperationsAreFinished()
    }
}

extension AttitudeReferenceFrame {
    var coreMotion: CMAttitudeReferenceFrame {
        switch self {
        case .xArbitraryZVertical: .xArbitraryZVertical
        case .xArbitraryCorrectedZVertical: .xArbitraryCorrectedZVertical
        case .xMagneticNorthZVertical: .xMagneticNorthZVertical
        case .xTrueNorthZVertical: .xTrueNorthZVertical
        }
    }

    var usesMagnetometer: Bool { self != .xArbitraryZVertical }

    var label: String {
        switch self {
        case .xArbitraryZVertical: "Arbitrary X, Z vertical"
        case .xArbitraryCorrectedZVertical: "Arbitrary X, Z vertical (mag-corrected)"
        case .xMagneticNorthZVertical: "Magnetic north (experimental)"
        case .xTrueNorthZVertical: "True north"
        }
    }
}

extension MagneticAccuracy {
    init(_ accuracy: CMMagneticFieldCalibrationAccuracy) {
        switch accuracy {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        default: self = .uncalibrated
        }
    }
}
