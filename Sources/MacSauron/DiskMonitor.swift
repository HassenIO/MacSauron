import Foundation
import IOKit

/// Disk throughput in bytes per second, summed over all block storage devices.
struct DiskRate {
    let read: Double
    let write: Double
}

/// Reads the cumulative byte counters IOKit keeps per block storage driver (what Activity Monitor uses).
final class DiskMonitor {
    private var previous: (read: UInt64, write: UInt64, time: Date)?

    /// Returns nil on the first call (no previous sample to diff against) or on error.
    func sample() -> DiskRate? {
        guard let totals = Self.readTotals() else { return nil }
        let now = Date()
        defer { previous = (totals.read, totals.write, now) }
        guard let prev = previous else { return nil }

        let elapsed = now.timeIntervalSince(prev.time)
        guard elapsed > 0 else { return nil }
        // Counters go backwards when a device (e.g. a disk image) is ejected; treat that as zero.
        let read = totals.read >= prev.read ? totals.read - prev.read : 0
        let write = totals.write >= prev.write ? totals.write - prev.write : 0
        return DiskRate(read: Double(read) / elapsed, write: Double(write) / elapsed)
    }

    private static func readTotals() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
            == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }
}
