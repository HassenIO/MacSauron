import Foundation
import Observation

struct CPUPoint: Identifiable {
    let date: Date
    let load: CPULoad
    var id: Date { date }
}

struct NetworkPoint: Identifiable {
    let date: Date
    let rate: NetworkRate
    var id: Date { date }
}

struct DiskPoint: Identifiable {
    let date: Date
    let rate: DiskRate
    var id: Date { date }
}

/// Everything the popover shows.
struct Metrics {
    var cpuHistory: [CPUPoint] = []
    var networkHistory: [NetworkPoint] = []
    var diskHistory: [DiskPoint] = []
    var memory: MemoryUsage?
    var battery: BatteryState?
    /// Readings MacSauron recorded itself (persisted).
    var recordedBattery: [BatteryPoint] = []
    /// Readings from the system power log (not persisted, reloaded on each launch).
    var powerLogBattery: [BatteryPoint] = []
    /// Apps using the most of each resource.
    var topCPU: [AppUsage] = []
    var topMemory: [AppUsage] = []
    var topNetwork: [AppUsage] = []
    var topDisk: [AppUsage] = []

    var cpu: CPULoad? { cpuHistory.last?.load }

    /// Battery readings for the last 12 hours, oldest first, ending with the live reading.
    /// The last reading older than the window is pinned to the window start, so the line spans the whole chart.
    var batteryHistory: [BatteryPoint] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-MetricsStore.batteryWindow)
        let all = (recordedBattery + powerLogBattery).sorted { $0.date < $1.date }
        var points = all.filter { $0.date >= cutoff }
        if let anchor = all.last(where: { $0.date < cutoff }) {
            points.insert(BatteryPoint(date: cutoff, percent: anchor.percent), at: 0)
        }
        if let battery { points.append(BatteryPoint(date: now, percent: battery.percent)) }
        return points
    }
}

/// Samples every metric on a single timer and keeps the short histories the UI draws.
///
/// Sampling always runs (histories must stay complete), but `metrics` is only republished
/// while the popover is visible, so the hidden charts are not re-rendered every tick.
@MainActor @Observable
final class MetricsStore {
    nonisolated static let sampleInterval: TimeInterval = 2
    nonisolated static let liveWindow: TimeInterval = 5 * 60
    nonisolated static let batteryWindow: TimeInterval = 12 * 60 * 60
    nonisolated static let batteryRecordInterval: TimeInterval = 60
    /// Readings are kept longer than the chart window so the chart start can be anchored.
    nonisolated static let batteryRetention: TimeInterval = 24 * 60 * 60
    nonisolated static let topAppCount = 4

    /// What the popover displays.
    private(set) var metrics = Metrics()
    /// Total CPU load for the menu bar label, updated every tick.
    private(set) var cpuTotal: Double?

    @ObservationIgnored var isPopoverVisible = false {
        didSet { if isPopoverVisible && !oldValue { metrics = live } }
    }

    @ObservationIgnored private var live = Metrics(recordedBattery: BatteryHistoryFile.load())
    @ObservationIgnored private let cpuMonitor = CPUMonitor()
    @ObservationIgnored private let memoryMonitor = MemoryMonitor()
    @ObservationIgnored private let networkMonitor = NetworkMonitor()
    @ObservationIgnored private let diskMonitor = DiskMonitor()
    @ObservationIgnored private let processMonitor = ProcessMonitor()
    @ObservationIgnored private let processNetworkMonitor = ProcessNetworkMonitor()

    init() {
        tick()
        metrics = live // initial layout (e.g. whether the battery section exists) must be right
        loadPowerLog()
        startProcessNetworkLoop()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sampleInterval))
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.liveWindow)

        if let load = cpuMonitor.sample() {
            live.cpuHistory.append(CPUPoint(date: now, load: load))
            live.cpuHistory.removeAll { $0.date < cutoff }
            cpuTotal = load.total
        }
        if let rate = networkMonitor.sample() {
            live.networkHistory.append(NetworkPoint(date: now, rate: rate))
            live.networkHistory.removeAll { $0.date < cutoff }
        }
        if let rate = diskMonitor.sample() {
            live.diskHistory.append(DiskPoint(date: now, rate: rate))
            live.diskHistory.removeAll { $0.date < cutoff }
        }
        live.memory = memoryMonitor.sample()
        let processes = processMonitor.sample(limit: Self.topAppCount)
        live.topCPU = processes.cpu
        live.topMemory = processes.memory
        live.topDisk = processes.disk
        live.battery = BatteryMonitor.read()
        recordBatteryIfNeeded(now: now)

        if isPopoverVisible { metrics = live }
    }

    private func recordBatteryIfNeeded(now: Date) {
        guard let battery = live.battery else { return }
        if let last = live.recordedBattery.last, now.timeIntervalSince(last.date) < Self.batteryRecordInterval { return }
        live.recordedBattery.append(BatteryPoint(date: now, percent: battery.percent))
        live.recordedBattery.removeAll { $0.date < now.addingTimeInterval(-Self.batteryRetention) }
        BatteryHistoryFile.save(live.recordedBattery)
    }

    /// Runs `nettop` back to back off the main thread (each run takes ~5s) to keep the per-app network list fresh.
    private func startProcessNetworkLoop() {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let counters = ProcessNetworkMonitor.readCounters() else {
                    try? await Task.sleep(for: .seconds(10)) // nettop unavailable; retry later without spinning
                    continue
                }
                guard let self else { return }
                await self.ingest(counters)
            }
        }
    }

    private func ingest(_ counters: ProcessNetworkMonitor.Counters) {
        guard let top = processNetworkMonitor.ingest(counters, limit: Self.topAppCount) else { return }
        live.topNetwork = top
        if isPopoverVisible { metrics.topNetwork = top }
    }

    /// Parses the system power log off the main thread to backfill the battery graph.
    private func loadPowerLog() {
        guard live.battery != nil else { return }
        let since = Date().addingTimeInterval(-Self.batteryRetention)
        Task.detached(priority: .utility) {
            let points = BatteryMonitor.readPowerLog(since: since)
            await MainActor.run { [weak self] in
                guard let self else { return }
                live.powerLogBattery = points
                if isPopoverVisible { metrics = live }
            }
        }
    }
}
