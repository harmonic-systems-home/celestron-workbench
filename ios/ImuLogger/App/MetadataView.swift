import ImuLoggerCore
import SwiftUI

/// Everything the app reports about the device in `hello`, plus live state.
struct MetadataView: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        let device = recorder.deviceInfo
        let availability = recorder.availability
        Form {
            Section("Device") {
                LabeledContent("Model", value: device.model)
                LabeledContent("iOS", value: device.osVersion)
                LabeledContent("App", value: device.appVersion)
                LabeledContent("Device ID", value: device.deviceId)
                    .font(.caption.monospaced())
                LabeledContent("Boot ID", value: device.bootId)
                    .font(.caption.monospaced())
            }
            Section {
                availabilityRow("Device motion (fused)", availability.deviceMotion)
                availabilityRow("Gyroscope", availability.gyro)
                availabilityRow("Accelerometer", availability.accel)
                availabilityRow("Magnetometer", availability.magnetometer)
            } header: {
                Text("Sensors")
            } footer: {
                Text("Discovered from Core Motion at launch.")
            }
            Section {
                ForEach(recorder.availableFrames, id: \.self) { frame in
                    Text(frame.label)
                }
            } header: {
                Text("Attitude reference frames")
            } footer: {
                Text(
                    "True north is not offered: it needs location services, and the observing site stays private."
                )
            }
            Section("Conditions") {
                LabeledContent("Thermal state", value: ProcessInfo.processInfo.thermalState.name)
                LabeledContent("Phone clock", value: "\(PhoneClock.nowNs()) ns since boot")
                    .font(.caption.monospaced())
            }
            Section {
                Text(
                    "The device ID is a random identifier created by this app, not a hardware identifier. Session files contain the model, iOS version, and sensor data, but no location."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Device and sensors")
    }

    private func availabilityRow(_ name: String, _ available: Bool) -> some View {
        LabeledContent(name) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(available ? .green : .secondary)
        }
    }
}
