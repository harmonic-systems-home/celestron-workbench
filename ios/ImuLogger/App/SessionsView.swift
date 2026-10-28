import SwiftUI

/// Session logs on the phone, for export via the share sheet or the Files app.
struct SessionsView: View {
    @Environment(Recorder.self) private var recorder
    @State private var files: [SessionFile] = []

    struct SessionFile: Identifiable {
        let url: URL
        let size: Int64
        let modified: Date
        var id: URL { url }
    }

    var body: some View {
        List {
            if files.isEmpty {
                Text("No sessions recorded yet.").foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                let isActive = recorder.session?.fileURL == file.url
                HStack {
                    VStack(alignment: .leading) {
                        Text(file.url.lastPathComponent).font(.callout.monospaced())
                        Text(
                            "\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))\(isActive ? " · recording" : "")"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isActive {
                        ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                    }
                }
                .deleteDisabled(isActive)
            }
            .onDelete { offsets in
                for index in offsets { try? FileManager.default.removeItem(at: files[index].url) }
                reload()
            }
        }
        .navigationTitle("Recorded sessions")
        .toolbar { EditButton() }
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        let directory = Recorder.sessionsDirectory
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys)) ?? []
        files = urls.filter { $0.pathExtension == "ndjson" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return SessionFile(
                url: url, size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }
}
