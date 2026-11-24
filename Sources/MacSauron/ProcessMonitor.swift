import Darwin
import Foundation

/// Resource usage of one app (all of its processes combined).
struct AppUsage: Identifiable, Equatable {
    let name: String
    /// File whose Finder icon represents the app (bundle or executable path).
    let iconPath: String?
    let value: Double
    /// Set when the app has been hogging the resource (see `ProcessMonitor.cpuWarningThreshold`).
    var isWarning = false
    var id: String { name }
}

/// The app a process belongs to: its outermost `.app` bundle, or the process itself.
struct AppIdentity: Hashable {
    let name: String
    let iconPath: String?

    /// `/Applications/Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/Contents/MacOS/...`
    /// -> "Google Chrome", so helper processes are counted under their app.
    init(executablePath path: String) {
        if let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            name = (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            iconPath = bundlePath
        } else {
            name = (path as NSString).lastPathComponent
            iconPath = path
        }
    }

    init(name: String) {
        self.name = name
        iconPath = nil
    }

    /// Identity of a running process, or nil if it has exited.
    static func of(pid: pid_t) -> AppIdentity? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return AppIdentity(executablePath: String(decoding: buffer.prefix(Int(length)), as: UTF8.self))
    }
}

/// Caches the app identity of each pid, keyed by pid and process start time so reused pids are not confused.
final class AppResolver {
    private struct Key: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    private var cache: [Key: AppIdentity] = [:]

    func identity(pid: pid_t, start: UInt64) -> AppIdentity? {
        let key = Key(pid: pid, start: start)
        if let cached = cache[key] { return cached }
        guard let identity = AppIdentity.of(pid: pid) else { return nil }
        cache[key] = identity
        return identity
    }

    /// Drops entries of processes that no longer exist.
    func prune(keeping pids: Set<pid_t>) {
        cache = cache.filter { pids.contains($0.key.pid) }
    }
}

/// Top apps for each resource read by `ProcessMonitor`.
struct ProcessSample {
    /// % of one core, like Activity Monitor.
    let cpu: [AppUsage]
    /// Physical footprint in bytes.
    let memory: [AppUsage]
    /// Disk read + write bytes per second.
    let disk: [AppUsage]
}

/// Per-app CPU, memory and disk IO, read with libproc.
/// Only processes owned by the current user are readable without a privileged helper.
final class ProcessMonitor {
    private struct Reading {
        let start: UInt64
        let cpuTime: UInt64 // nanoseconds
        let diskBytes: UInt64 // read + written since process start
    }

    private let resolver = AppResolver()
    private let nanosPerTick: Double
    private var previous: [pid_t: Reading] = [:]
    private var previousTime: Date?
    /// Per-app CPU of the most recent samples, oldest first, used for the sustained-load warning.
    private var cpuWindow: [[AppIdentity: Double]] = []

    /// An app averaging more than this CPU % (100 = one core) over `cpuWarningSamples` samples is flagged.
    static let cpuWarningThreshold: Double = 75
    /// 15 samples at 2s per tick = 30 seconds.
    static let cpuWarningSamples = 15

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosPerTick = Double(timebase.numer) / Double(timebase.denom)
    }

    /// The CPU and disk lists are empty on the first call (no previous sample to diff against).
    func sample(limit: Int) -> ProcessSample {
        let now = Date()
        let elapsed = previousTime.map { now.timeIntervalSince($0) * 1e9 } ?? 0
        var cpuByApp: [AppIdentity: Double] = [:]
        var memoryByApp: [AppIdentity: Double] = [:]
        var diskByApp: [AppIdentity: Double] = [:]
        var current: [pid_t: Reading] = [:]

        for pid in Self.allPids() {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0,
                  let app = resolver.identity(pid: pid, start: info.ri_proc_start_abstime) else { continue }

            let cpuTime = UInt64(Double(info.ri_user_time + info.ri_system_time) * nanosPerTick)
            let diskBytes = info.ri_diskio_bytesread + info.ri_diskio_byteswritten
            let reading = Reading(start: info.ri_proc_start_abstime, cpuTime: cpuTime, diskBytes: diskBytes)
            current[pid] = reading
            memoryByApp[app, default: 0] += Double(info.ri_phys_footprint)

            if elapsed > 0, let prev = previous[pid], prev.start == reading.start {
                if cpuTime >= prev.cpuTime {
                    cpuByApp[app, default: 0] += Double(cpuTime - prev.cpuTime) / elapsed * 100
                }
                if diskBytes >= prev.diskBytes {
                    diskByApp[app, default: 0] += Double(diskBytes - prev.diskBytes) / elapsed * 1e9
                }
            }
        }

        previous = current
        previousTime = now
        resolver.prune(keeping: Set(current.keys))

        if elapsed > 0 {
            cpuWindow.append(cpuByApp)
            if cpuWindow.count > Self.cpuWarningSamples { cpuWindow.removeFirst() }
        }
        return ProcessSample(
            cpu: Self.top(cpuByApp, limit: limit, warned: appsHoggingCPU()),
            memory: Self.top(memoryByApp, limit: limit),
            disk: Self.top(diskByApp, limit: limit, minimum: Self.minimumThroughput)
        )
    }

    /// Apps whose CPU averaged above the threshold over a full 30s window.
    private func appsHoggingCPU() -> Set<AppIdentity> {
        guard cpuWindow.count == Self.cpuWarningSamples else { return [] }
        var totals: [AppIdentity: Double] = [:]
        for sample in cpuWindow {
            totals.merge(sample, uniquingKeysWith: +)
        }
        return Set(totals.filter { $0.value / Double(cpuWindow.count) > Self.cpuWarningThreshold }.keys)
    }

    /// Throughput below this (bytes/s) would display as "0 KB/s", so it is left out of top lists.
    static let minimumThroughput: Double = 1_000

    /// The `limit` largest values above `minimum`, flagging apps in `warned`.
    static func top(
        _ values: [AppIdentity: Double], limit: Int, minimum: Double = 0, warned: Set<AppIdentity> = []
    ) -> [AppUsage] {
        values
            .filter { $0.value > minimum }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map {
                AppUsage(name: $0.key.name, iconPath: $0.key.iconPath, value: $0.value, isWarning: warned.contains($0.key))
            }
    }

    private static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64) // headroom for processes spawned meanwhile
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }
}
