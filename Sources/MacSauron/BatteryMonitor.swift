import Foundation
import IOKit.ps

struct BatteryState {
    let percent: Double
    let isCharging: Bool
    let onAC: Bool
    /// Minutes until empty (on battery) or full (charging); nil while macOS is still estimating.
    let minutesRemaining: Int?
}

struct BatteryPoint: Codable, Equatable {
    let date: Date
    let percent: Double
}

enum BatteryMonitor {
    /// Current state of the internal battery, or nil when the Mac has no battery.
    static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }

            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = desc[minutesKey] as? Int
            return BatteryState(
                percent: Double(current) / Double(max) * 100,
                isCharging: isCharging,
                onAC: onAC,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
        }
        return nil
    }

    /// Charge readings logged by the power management daemon (`pmset -g log`) since `since`,
    /// preceded by the latest reading before `since` (if any).
    /// Used to backfill the history for periods when MacSauron was not running.
    static func readPowerLog(since: Date) -> [BatteryPoint] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return parsePowerLog(output, since: since)
    }

    /// Matches lines such as:
    /// `2026-11-24 15:24:01 +0400 Assertions  Summary- [...] Using AC(Charge: 100)`
    /// `2026-11-24 15:24:01 +0400 Sleep  Entering Sleep ... Using Batt (Charge:85%) ...`
    static func parsePowerLog(_ log: String, since: Date) -> [BatteryPoint] {
        let regex = /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}) .*Using [A-Za-z]+ ?\(Charge: ?(\d+)%?\)/
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        var points: [BatteryPoint] = []
        var lastBefore: BatteryPoint?
        for line in log.split(separator: "\n") where line.contains("Charge:") {
            guard let match = line.firstMatch(of: regex),
                  let date = formatter.date(from: String(match.1)),
                  let percent = Double(match.2) else { continue }
            let point = BatteryPoint(date: date, percent: percent)
            if date >= since { points.append(point) } else { lastBefore = point }
        }
        // The log only has entries on power events, so the latest older entry is the charge at `since`.
        if let lastBefore { points.insert(lastBefore, at: 0) }
        return points
    }
}

/// Battery readings recorded by MacSauron itself, persisted across launches.
struct BatteryHistoryFile {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacSauron/battery.json")

    static func load() -> [BatteryPoint] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BatteryPoint].self, from: data)) ?? []
    }

    static func save(_ points: [BatteryPoint]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(points).write(to: url, options: .atomic)
        } catch {
            NSLog("MacSauron: failed to save battery history: \(error)")
        }
    }
}
