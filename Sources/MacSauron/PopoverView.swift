import Charts
import SwiftUI

struct PopoverView: View {
    let store: MetricsStore

    var body: some View {
        let metrics = store.metrics
        VStack(alignment: .leading, spacing: 0) {
            SectionRow {
                CPUSection(metrics: metrics)
            } right: {
                ThroughputSection(
                    title: "Network", symbol: "network",
                    points: metrics.networkHistory.map { RatePoint(date: $0.date, first: $0.rate.bytesIn, second: $0.rate.bytesOut) },
                    first: ("Received", .blue), second: ("Sent", .orange),
                    topApps: metrics.topNetwork
                )
            }
            Divider().padding(.vertical, 12)
            SectionRow {
                MemorySection(history: metrics.memoryHistory, topApps: metrics.topMemory)
            } right: {
                ThroughputSection(
                    title: "Disk", symbol: "internaldrive",
                    points: metrics.diskHistory.map { RatePoint(date: $0.date, first: $0.rate.read, second: $0.rate.write) },
                    first: ("Read", .blue), second: ("Write", .red),
                    topApps: metrics.topDisk
                )
            }
            if metrics.battery != nil {
                Divider().padding(.vertical, 12)
                BatterySection(metrics: metrics)
            }
            Divider().padding(.vertical, 12)
            Footer()
        }
        .padding(16)
        .frame(width: 2 * Self.columnWidth + Self.columnSpacing + 32)
    }

    static let columnWidth: CGFloat = 300
    static let columnSpacing: CGFloat = 32
}

/// Two sections side by side with equal heights, so their top-apps lists line up at the bottom.
private struct SectionRow<Left: View, Right: View>: View {
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(alignment: .top, spacing: PopoverView.columnSpacing) {
            left.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            right.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sections

private struct CPUSection: View {
    let metrics: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "CPU", symbol: "cpu", value: metrics.cpu.map { Format.percent($0.total) })
            Chart {
                ForEach(metrics.cpuHistory) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Load", point.load.system * 100))
                        .foregroundStyle(by: .value("Type", "System"))
                    AreaMark(x: .value("Time", point.date), y: .value("Load", point.load.user * 100))
                        .foregroundStyle(by: .value("Type", "User"))
                }
            }
            .chartForegroundStyleScale(["System": Color.red, "User": Color.blue])
            .chartYScale(domain: 0...100)
            .chartXScale(domain: liveDomain())
            .chartYAxis { percentAxis() }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 64)
            StatRow(items: [
                ("User", Format.percent(metrics.cpu?.user ?? 0), .blue),
                ("System", Format.percent(metrics.cpu?.system ?? 0), .red),
                ("Idle", Format.percent(1 - (metrics.cpu?.total ?? 0)), .secondary),
            ])
            Spacer(minLength: 0)
            TopApps(apps: metrics.topCPU, format: Format.cpuPercent)
        }
    }
}

private struct MemorySection: View {
    let history: [MemoryPoint]
    let topApps: [AppUsage]

    var body: some View {
        let memory = history.last?.usage
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "Memory",
                symbol: "memorychip",
                value: memory.map { "\(Format.gigabytes($0.used)) / \($0.physical >> 30) GB" }
            )
            // Pressure colored by level, like Activity Monitor. One stacked series per level, where a sample counts
            // only towards its own level, draws each color as a single seamless area.
            Chart {
                ForEach(history) { point in
                    ForEach(MemoryPressure.allCases, id: \.self) { level in
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("Pressure", point.usage.pressure == level ? point.usage.pressurePercent : 0)
                        )
                        .foregroundStyle(by: .value("Level", level.rawValue))
                        .interpolationMethod(.stepStart)
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: MemoryPressure.allCases.map(\.rawValue),
                range: MemoryPressure.allCases.map(pressureColor)
            )
            .chartLegend(.hidden)
            .chartYScale(domain: 0...100)
            .chartXScale(domain: liveDomain())
            .chartYAxis { percentAxis() }
            .chartXAxis(.hidden)
            .frame(height: 64)
            if let memory {
                StatRow(items: [
                    ("App", Format.gigabytes(memory.app), .blue),
                    ("Wired", Format.gigabytes(memory.wired), .orange),
                    ("Compressed", Format.gigabytes(memory.compressed), .purple),
                ])
                StatRow(items: [
                    ("Cached", Format.gigabytes(memory.cached), .teal),
                    ("Swap", Format.gigabytes(memory.swapUsed), .secondary),
                    ("Pressure", memory.pressure.rawValue, pressureColor(memory.pressure)),
                ])
            }
            Spacer(minLength: 0)
            TopApps(apps: topApps) { Format.memory(UInt64($0)) }
        }
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

struct RatePoint: Identifiable {
    let date: Date
    let first: Double
    let second: Double
    var id: Date { date }
}

/// Two rates over the live window (e.g. received / sent), their current values, and the top apps.
private struct ThroughputSection: View {
    let title: String
    let symbol: String
    let points: [RatePoint]
    let first: (label: String, color: Color)
    let second: (label: String, color: Color)
    let topApps: [AppUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, symbol: symbol, value: nil)
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Rate", point.first))
                        .foregroundStyle(by: .value("Series", first.label))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    LineMark(x: .value("Time", point.date), y: .value("Rate", point.second))
                        .foregroundStyle(by: .value("Series", second.label))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartForegroundStyleScale([first.label: first.color, second.label: second.color])
            .chartXScale(domain: liveDomain())
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let rate = value.as(Double.self) { Text(Format.rate(rate)).font(.system(size: 8)) }
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 64)
            StatRow(items: [
                (first.label, Format.rate(points.last?.first ?? 0), first.color),
                (second.label, Format.rate(points.last?.second ?? 0), second.color),
            ])
            Spacer(minLength: 0)
            TopApps(apps: topApps, format: Format.rate)
        }
    }
}

private struct BatterySection: View {
    let metrics: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "Battery",
                symbol: batterySymbol,
                value: metrics.battery.map { Format.percent($0.percent / 100) }
            )
            Chart {
                ForEach(metrics.batteryHistory, id: \.date) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Charge", point.percent))
                        .foregroundStyle(.green.opacity(0.25))
                    LineMark(x: .value("Time", point.date), y: .value("Charge", point.percent))
                        .foregroundStyle(.green)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: Date().addingTimeInterval(-MetricsStore.batteryWindow)...Date())
            .chartYAxis { percentAxis() }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                    AxisGridLine()
                    // A label starting in the last hour has no room before the chart edge and would show as "...".
                    if let date = value.as(Date.self), date < Date().addingTimeInterval(-60 * 60) {
                        AxisValueLabel(format: .dateTime.hour(), centered: false).font(.system(size: 8))
                    }
                }
            }
            .frame(height: 72)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var batterySymbol: String {
        guard let battery = metrics.battery else { return "battery.0percent" }
        if battery.isCharging || battery.onAC { return "battery.100percent.bolt" } // like macOS: bolt whenever plugged in
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var statusText: String {
        guard let battery = metrics.battery else { return "" }
        let remaining = battery.minutesRemaining.map(Format.minutes)
        if battery.isCharging {
            return remaining.map { "Charging - \($0) until full" } ?? "Charging"
        }
        if battery.onAC { return "On power adapter" }
        return remaining.map { "On battery - \($0) remaining" } ?? "On battery"
    }
}

private struct Footer: View {
    var body: some View {
        HStack {
            Button("Open Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

// MARK: - Building blocks

private struct SectionHeader: View {
    let title: String
    let symbol: String
    let value: String?

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.headline)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
    }
}

/// The apps using the most of a resource: icon, name and formatted value.
/// Always lays out `MetricsStore.topAppCount` rows so the popover height never jumps.
private struct TopApps: View {
    let apps: [AppUsage]
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<MetricsStore.topAppCount, id: \.self) { index in
                if index < apps.count {
                    row(apps[index])
                } else {
                    Color.clear.frame(height: rowHeight)
                }
            }
        }
        .padding(.top, 2)
    }

    private let rowHeight: CGFloat = 16

    private func row(_ app: AppUsage) -> some View {
        HStack(spacing: 6) {
            if app.isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(width: 14, height: 14)
                    .help("Above 75% CPU for the last 30 seconds")
            } else {
                AppIcon(path: app.iconPath)
            }
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(format(app.value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(height: rowHeight)
    }
}

/// Finder icon of an app or executable, cached per path.
private struct AppIcon: View {
    let path: String?

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 14, height: 14)
    }

    private var icon: NSImage {
        let key = path ?? ""
        if let cached = Self.cache[key] { return cached }
        let source = path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
        let image = Self.rasterize(source)
        Self.cache[key] = image
        return image
    }

    /// Workspace icons are lazy multi-resolution images; draw once into a small @2x bitmap.
    private static func rasterize(_ source: NSImage) -> NSImage {
        let pixels = 28
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: 14, height: 14)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Up to three labelled values in equal-width columns, each with a colored dot.
private struct StatRow: View {
    let items: [(label: String, value: String, color: Color)]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    Text(item.value)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(items.count..<3, id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }
}

private func liveDomain() -> ClosedRange<Date> {
    Date().addingTimeInterval(-MetricsStore.liveWindow)...Date()
}

private func percentAxis() -> some AxisContent {
    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
        AxisGridLine()
        AxisValueLabel {
            if let percent = value.as(Int.self) { Text("\(percent)%").font(.system(size: 8)) }
        }
    }
}
