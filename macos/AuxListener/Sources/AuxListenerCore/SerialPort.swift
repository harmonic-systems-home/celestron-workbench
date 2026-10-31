import Foundation
import IOKit
import IOKit.serial

/// The listener's USB-to-TTL cable: FTDI's USB vendor ID (ADR 0018). The
/// hand controller's cable is Prolific (0x067B) and is never opened here.
public let ftdiVendorID = 0x0403

/// Serial ports (`/dev/cu.*`) whose USB device has the given vendor ID.
public func serialPorts(vendorID: Int) -> [String] {
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching(kIOSerialBSDServiceValue)
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var ports: [String] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        guard
            let path = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
            let vendor = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
                as? Int,
            vendor == vendorID
        else { continue }
        ports.append(path)
    }
    return ports.sorted()
}

public enum SerialError: Error, CustomStringConvertible {
    case open(String, Int32)
    case configure(String, Int32)

    public var description: String {
        switch self {
        case .open(let path, let e): "couldn't open \(path): \(String(cString: strerror(e)))"
        case .configure(let path, let e):
            "couldn't configure \(path): \(String(cString: strerror(e)))"
        }
    }
}

/// Reads a serial port at 19,200 8N1, read-only: the port is opened without
/// write access, so nothing can be sent to the bus (ADR 0018). Each read is
/// handed over with the monotonic time it arrived.
public final class SerialReader: @unchecked Sendable {
    public let path: String
    private let fd: Int32
    private let source: DispatchSourceRead
    private var closed = false

    /// `onBytes` and `onClose` run on `queue`, in order.
    public init(
        path: String, queue: DispatchQueue,
        onBytes: @escaping @Sendable ([UInt8], UInt64) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) throws {
        self.path = path
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.open(path, errno) }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SerialError.configure(path, e)
        }
        cfmakeraw(&t)
        cfsetispeed(&t, speed_t(B19200))
        cfsetospeed(&t, speed_t(B19200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        t.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SerialError.configure(path, e)
        }
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = read(self.fd, &buffer, buffer.count)
            let t = monotonicNs()
            if n > 0 {
                onBytes(Array(buffer[0..<n]), t)
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                // The cable was unplugged.
                self.close()
                onClose()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
    }

    deinit { close() }
}
