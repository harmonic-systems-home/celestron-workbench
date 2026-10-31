import Foundation
import IOKit
import IOKit.serial

/// The hand controller's USB serial chip: Prolific (ADR 0010's discovery).
public let prolificVendorID = 0x067B

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
