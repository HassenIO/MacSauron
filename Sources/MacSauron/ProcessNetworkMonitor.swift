import Darwin
import Foundation

/// Per-app network throughput (received + sent bytes per second).
///
/// There is no public per-process network API, so this reads cumulative per-process byte
/// counters from `nettop` and diffs consecutive runs. A run costs little CPU but takes ~5s.
final class ProcessNetworkMonitor {
    /// Cumulative bytes (in + out) per process, as reported by one `nettop` run.
    struct Counters: Sendable {
        let date: Date
        let bytes: [pid_t: UInt64]
        let names: [pid_t: String]
    }

    private var previous: Counters?
    private var identities: [pid_t: AppIdentity] = [:]

    /// Feeds a new `nettop` run and returns the top apps by throughput since the previous run.
    /// Returns nil on the first call (no previous run to diff against).
    func ingest(_ counters: Counters, limit: Int) -> [AppUsage]? {
        defer { previous = counters }
        identities = identities.filter { counters.bytes[$0.key] != nil }
        guard let prev = previous else { return nil }
        let elapsed = counters.date.timeIntervalSince(prev.date)
        guard elapsed > 0 else { return nil }

        var rateByApp: [AppIdentity: Double] = [:]
        for (pid, bytes) in counters.bytes {
            guard let prevBytes = prev.bytes[pid], bytes > prevBytes else { continue }
            rateByApp[identity(pid: pid, fallbackName: counters.names[pid]), default: 0] += Double(bytes - prevBytes) / elapsed
        }
        return ProcessMonitor.top(rateByApp, limit: limit)
    }

    private func identity(pid: pid_t, fallbackName: String?) -> AppIdentity {
        if let cached = identities[pid] { return cached }
        let identity = AppIdentity.of(pid: pid) ?? AppIdentity(name: fallbackName ?? "pid \(pid)")
        identities[pid] = identity
        return identity
    }

    /// Runs `nettop` once (blocks ~5s). Returns nil if it could not run.
    static func readCounters() -> Counters? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        let (bytes, names) = parse(output)
        return Counters(date: Date(), bytes: bytes, names: names)
    }

    /// Parses lines such as `Brave Browser H.3027,1849,376,` (process name truncated by nettop, then `.pid`).
    static func parse(_ output: String) -> (bytes: [pid_t: UInt64], names: [pid_t: String]) {
        var bytes: [pid_t: UInt64] = [:]
        var names: [pid_t: String] = [:]
        for line in output.split(separator: "\n").dropFirst() { // first line is the header
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = UInt64(fields[1]),
                  let bytesOut = UInt64(fields[2]) else { continue }
            bytes[pid, default: 0] += bytesIn + bytesOut
            names[pid] = String(fields[0][..<dot])
        }
        return (bytes, names)
    }
}
