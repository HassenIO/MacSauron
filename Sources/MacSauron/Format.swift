import Foundation

enum Format {
    /// 0.123 -> "12%"
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// 17179869184 -> "16.0 GB" (binary GB, one decimal, like Activity Monitor)
    static func gigabytes(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    /// 1250000 -> "1.3 MB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false // "0 KB" instead of "Zero KB"
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// 135 -> "2:15"
    static func minutes(_ value: Int) -> String {
        String(format: "%d:%02d", value / 60, value % 60)
    }
}
