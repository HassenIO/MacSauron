import Darwin

/// CPU load as a fraction of total CPU time (0...1), averaged over all cores.
struct CPULoad {
    let user: Double
    let system: Double
    var total: Double { user + system }
}

/// Reads aggregated CPU ticks from the kernel and returns the load since the previous call.
final class CPUMonitor {
    private let host = mach_host_self()
    private var previous: host_cpu_load_info?

    /// Returns nil on the first call (no previous sample to diff against) or on error.
    func sample() -> CPULoad? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let prev = previous else { return nil }

        // cpu_ticks order: user, system, idle, nice
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0) + Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let total = user + system + idle
        guard total > 0 else { return nil }
        return CPULoad(user: user / total, system: system / total)
    }
}
