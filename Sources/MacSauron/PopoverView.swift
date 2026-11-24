import Charts
import SwiftUI

struct PopoverView: View {
    let store: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CPUSection(metrics: store.metrics)
            Divider().padding(.vertical, 12)
            MemorySection(memory: store.metrics.memory)
            Divider().padding(.vertical, 12)
            NetworkSection(metrics: store.metrics)
            if store.metrics.battery != nil {
                Divider().padding(.vertical, 12)
                BatterySection(metrics: store.metrics)
            }
            Divider().padding(.vertical, 12)
            Footer()
        }
        .padding(16)
        .frame(width: 340)
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
        }
    }
}

private struct MemorySection: View {
    let memory: MemoryUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "Memory",
                symbol: "memorychip",
                value: memory.map { "\(Format.gigabytes($0.used)) / \($0.physical >> 30) GB" }
            )
            if let memory {
                MemoryBar(memory: memory)
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

/// Horizontal bar splitting physical memory into app / wired / compressed / cached / free.
private struct MemoryBar: View {
    let memory: MemoryUsage

    var body: some View {
        let segments: [(UInt64, Color)] = [
            (memory.app, .blue), (memory.wired, .orange), (memory.compressed, .purple), (memory.cached, .teal),
        ]
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { index in
                    segments[index].1
                        .frame(width: geo.size.width * fraction(segments[index].0))
                }
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10)
    }

    private func fraction(_ value: UInt64) -> CGFloat {
        memory.physical > 0 ? CGFloat(value) / CGFloat(memory.physical) : 0
    }
}

private struct NetworkSection: View {
    let metrics: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Network", symbol: "network", value: nil)
            Chart {
                ForEach(metrics.networkHistory) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Rate", point.rate.bytesIn))
                        .foregroundStyle(by: .value("Direction", "Received"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    LineMark(x: .value("Time", point.date), y: .value("Rate", point.rate.bytesOut))
                        .foregroundStyle(by: .value("Direction", "Sent"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartForegroundStyleScale(["Received": Color.blue, "Sent": Color.orange])
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
                ("Received", Format.rate(metrics.network?.bytesIn ?? 0), .blue),
                ("Sent", Format.rate(metrics.network?.bytesOut ?? 0), .orange),
            ])
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
                AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(), centered: false).font(.system(size: 8))
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
        if battery.isCharging { return "battery.100percent.bolt" }
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
