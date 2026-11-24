import Darwin

enum MemoryPressure: String {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
}

/// Memory figures in bytes, using the same definitions as Activity Monitor.
struct MemoryUsage {
    let physical: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let swapUsed: UInt64
    let pressure: MemoryPressure

    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { physical > used + cached ? physical - used - cached : 0 }
}

final class MemoryMonitor {
    private let host = mach_host_self()
    private let physical: UInt64 = sysctlValue("hw.memsize") ?? 0
    private let pageSize: UInt64

    init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = UInt64(size)
    }

    func sample() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = pageSize
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let swap: xsw_usage = sysctlValue("vm.swapusage") ?? xsw_usage()
        let level: Int32 = sysctlValue("kern.memorystatus_vm_pressure_level") ?? 1

        return MemoryUsage(
            physical: physical,
            app: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swap.xsu_used,
            pressure: level >= 4 ? .critical : level >= 2 ? .warning : .normal
        )
    }
}

/// Reads a fixed-size sysctl value by name.
func sysctlValue<T>(_ name: String) -> T? {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    var size = MemoryLayout<T>.size
    guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
    return pointer.pointee
}
