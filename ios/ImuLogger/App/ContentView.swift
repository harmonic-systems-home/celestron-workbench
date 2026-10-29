import ImuLoggerCore
import SwiftUI

struct ContentView: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        NavigationStack {
            Form {
                ReceiverSection()
                SessionSection()
                if recorder.isRecording {
                    MarkerSection()
                    LiveSection()
                }
                SettingsSection()
                Section {
                    NavigationLink("Device and sensors") { MetadataView() }
                    NavigationLink("Recorded sessions") { SessionsView() }
                }
            }
            .navigationTitle("IMU Logger")
        }
    }
}

// MARK: - Receiver

private struct ReceiverSection: View {
    @Environment(Recorder.self) private var recorder
    @Environment(ReceiverBrowser.self) private var browser

    var body: some View {
        @Bindable var recorder = recorder
        Section {
            Picker("Send to", selection: $recorder.receiverChoice) {
                Text("Nowhere (log on phone only)").tag(Recorder.ReceiverChoice.none)
                ForEach(browser.receivers) { receiver in
                    Text(receiver.name).tag(Recorder.ReceiverChoice.discovered(receiver.endpoint))
                }
                Text("Enter address…").tag(Recorder.ReceiverChoice.manual)
            }
            .disabled(recorder.isRecording)
            if recorder.receiverChoice == .manual {
                TextField("Mac host name or address", text: $recorder.manualHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(recorder.isRecording)
                TextField("Port", text: $recorder.manualPort)
                    .keyboardType(.numberPad)
                    .disabled(recorder.isRecording)
            }
            if recorder.isRecording {
                ConnectionStatusRow(
                    status: recorder.snapshot.uplink, hasReceiver: recorder.receiverEndpoint != nil)
            }
        } header: {
            Text("Mac receiver")
        } footer: {
            if let problem = browser.problem { Text(problem) }
        }
    }
}

private struct ConnectionStatusRow: View {
    let status: Uplink.Status?
    let hasReceiver: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "circle.fill")
                .foregroundStyle(color)
            if let status {
                Text(
                    "Acknowledged to seq \(status.acknowledged.map(String.init) ?? "–") · \(status.unacknowledgedSamples) unacknowledged · \(status.reconnects) reconnects"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = status.lastError {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var title: String {
        guard hasReceiver else { return "Not sending; recording to phone only" }
        switch status?.state {
        case .none, .idle: return "Starting"
        case .connecting(let attempt): return "Connecting (attempt \(attempt))"
        case .handshaking: return "Handshaking"
        case .streaming: return "Streaming"
        case .waitingToRetry(_, let delay):
            return String(format: "Disconnected, retrying in %.1f s", delay)
        case .rejected(let reason): return "Rejected: \(reason)"
        case .finished: return "Finished"
        }
    }

    private var color: Color {
        guard hasReceiver else { return .gray }
        switch status?.state {
        case .streaming: return .green
        case .rejected: return .red
        case .waitingToRetry: return .orange
        default: return .yellow
        }
    }
}

// MARK: - Session

private struct SessionSection: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        Section("Session") {
            if let session = recorder.session {
                LabeledContent("Session", value: String(session.id.prefix(8)))
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    LabeledContent(
                        "Elapsed",
                        value: Duration.seconds(context.date.timeIntervalSince(session.startedAt))
                            .formatted(.time(pattern: .hourMinuteSecond)))
                }
                Button(role: .destructive) {
                    recorder.stop()
                } label: {
                    Label("Stop recording", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    recorder.start()
                } label: {
                    Label("Start recording", systemImage: "record.circle").frame(
                        maxWidth: .infinity)
                }
                .disabled(recorder.selectedStreams.isEmpty)
                if let file = recorder.lastFinishedFile {
                    LabeledContent("Last session", value: file.lastPathComponent)
                }
            }
            if let error = recorder.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

private struct MarkerSection: View {
    @Environment(Recorder.self) private var recorder
    @State private var label = ""

    var body: some View {
        Section {
            TextField("Marker label (optional)", text: $label)
                .autocorrectionDisabled()
            Button {
                recorder.addMarker(label: label)
                label = ""
            } label: {
                Label("Add marker", systemImage: "flag.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } header: {
            Text("Markers")
        } footer: {
            Text("\(recorder.markerCount) placed. Markers are timestamped on the phone clock.")
        }
    }
}

// MARK: - Live statistics

private struct LiveSection: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        let snapshot = recorder.snapshot
        Section {
            ForEach(recorder.session?.streams ?? [], id: \.self) { stream in
                let summary = snapshot.rates[stream]
                LabeledContent(stream.label) {
                    VStack(alignment: .trailing) {
                        Text(
                            summary?.rateHz.map { String(format: "%.1f Hz observed", $0) }
                                ?? "waiting")
                        if let min = summary?.minIntervalNs, let max = summary?.maxIntervalNs {
                            Text(
                                String(
                                    format: "interval %.2f–%.2f ms", Double(min) / 1e6,
                                    Double(max) / 1e6)
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            LabeledContent("Samples", value: "\(snapshot.samples)")
            LabeledContent("Dropped on phone", value: "\(snapshot.dropped)")
                .foregroundStyle(snapshot.dropped > 0 ? .orange : .primary)
            LabeledContent("Buffer high water", value: "\(snapshot.bufferHighWater)")
            if let rotation = snapshot.rotationFromStartRad {
                LabeledContent(
                    "Rotation from start", value: String(format: "%.3f°", rotation * 180 / .pi))
            }
            LabeledContent("Attitude discontinuities", value: "\(snapshot.discontinuities)")
                .foregroundStyle(snapshot.discontinuities > 0 ? .orange : .primary)
            if let error = snapshot.logError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Live")
        } footer: {
            Text("Rates are what the phone actually delivered, measured from sensor timestamps.")
        }
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder
        Section {
            Picker("Requested rate", selection: $recorder.requestedRateHz) {
                ForEach(Recorder.rateOptionsHz, id: \.self) { rate in
                    Text("\(Int(rate)) Hz").tag(rate)
                }
            }
            if recorder.availableFrames.isEmpty {
                LabeledContent("Reference frame", value: "None available")
            } else {
                Picker("Reference frame", selection: $recorder.referenceFrame) {
                    ForEach(recorder.availableFrames, id: \.self) { frame in
                        Text(frame.label).tag(frame)
                    }
                }
            }
            Toggle("Raw gyroscope", isOn: $recorder.recordRawGyro)
                .disabled(!recorder.availability.gyro)
            Toggle("Raw accelerometer", isOn: $recorder.recordRawAccel)
                .disabled(!recorder.availability.accel)
            Toggle("Raw magnetometer", isOn: $recorder.recordRawMagnetometer)
                .disabled(!recorder.availability.magnetometer)
        } header: {
            Text("Recording settings")
        } footer: {
            Text(
                "The requested rate is a request to Core Motion; the delivered rate is measured and recorded. Fused device motion is always recorded when available. Prefer an arbitrary-X frame for bench work; magnetic frames are experimental near the mount."
            )
        }
        .disabled(recorder.isRecording)
    }
}

extension SensorStream {
    var label: String {
        switch self {
        case .deviceMotion: "Device motion"
        case .gyro: "Gyroscope"
        case .accel: "Accelerometer"
        case .magnetometer: "Magnetometer"
        }
    }
}
