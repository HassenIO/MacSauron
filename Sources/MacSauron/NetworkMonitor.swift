import Darwin
import Foundation

/// Network throughput in bytes per second, summed over all non-loopback interfaces.
struct NetworkRate {
    let bytesIn: Double
    let bytesOut: Double
}

final class NetworkMonitor {
    private var previous: (bytesIn: UInt64, bytesOut: UInt64, time: Date)?

    /// Returns nil on the first call (no previous sample to diff against) or on error.
    func sample() -> NetworkRate? {
        guard let totals = Self.readTotals() else { return nil }
        let now = Date()
        defer { previous = (totals.bytesIn, totals.bytesOut, now) }
        guard let prev = previous else { return nil }

        let elapsed = now.timeIntervalSince(prev.time)
        guard elapsed > 0 else { return nil }
        // Counters can go backwards when an interface disappears; treat that as zero traffic.
        let deltaIn = totals.bytesIn >= prev.bytesIn ? totals.bytesIn - prev.bytesIn : 0
        let deltaOut = totals.bytesOut >= prev.bytesOut ? totals.bytesOut - prev.bytesOut : 0
        return NetworkRate(bytesIn: Double(deltaIn) / elapsed, bytesOut: Double(deltaOut) / elapsed)
    }

    /// Sums the 64-bit byte counters of every interface via the NET_RT_IFLIST2 routing sysctl.
    private static func readTotals() -> (bytesIn: UInt64, bytesOut: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return nil }
        length += 1024 // the interface list can grow between the two calls
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if info.ifm_flags & IFF_LOOPBACK == 0 {
                        bytesIn += info.ifm_data.ifi_ibytes
                        bytesOut += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (bytesIn, bytesOut)
    }
}
