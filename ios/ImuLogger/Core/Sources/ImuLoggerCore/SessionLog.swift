import Foundation

/// The phone's authoritative NDJSON copy of a session (ADR 0006): one protocol
/// message per line, written before the message is sent.
public final class SessionLog: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var linesSinceSync = 0

    /// Creates a new log file. Fails if the file already exists.
    public init(creating url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_EXCL: never overwrite an existing session.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.url = url
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public func append(_ message: Message) throws {
        var line = try WireCoding.encode(message)
        line.append(0x0A)
        try lock.withLock {
            try handle.write(contentsOf: line)
            linesSinceSync += 1
            if linesSinceSync >= 50 {
                try handle.synchronize()
                linesSinceSync = 0
            }
        }
    }

    public func close() throws {
        try lock.withLock {
            try handle.synchronize()
            try handle.close()
        }
    }

    /// Reads every message in a log. A truncated final line (from a crash
    /// mid-write) is skipped; any other bad line throws.
    public static func read(_ url: URL) throws -> [Message] {
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var messages: [Message] = []
        for (index, line) in lines.enumerated() {
            do {
                messages.append(try WireCoding.decode(Data(line)))
            } catch  where index == lines.count - 1 && data.last != 0x0A {
                break
            }
        }
        return messages
    }

    /// Sample batches in a log that contain anything after `seq` (all of them if nil).
    public static func batches(in url: URL, after seq: Seq?) throws -> [SampleBatch] {
        try read(url).compactMap { message in
            guard case .sampleBatch(let batch) = message else { return nil }
            if let seq, batch.lastSeq <= seq { return nil }
            return batch
        }
    }
}
