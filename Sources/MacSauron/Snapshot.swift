import SwiftUI

/// Dev helper: `MacSauron --snapshot <dir> [seconds]` samples metrics for 15 seconds (or `seconds`),
/// writes the popover rendered in light and dark mode as PNGs to <dir>, then exits.
/// Lets the UI be inspected without screen recording permission.
enum Snapshot {
    static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    private static var delay: Double {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 2 < args.count else { return 15 }
        return Double(args[index + 2]) ?? 15
    }

    @MainActor
    static func run(store: MetricsStore, to directory: URL) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            store.isPopoverVisible = true // offscreen rendering has no window to report visibility
            for scheme in [ColorScheme.light, .dark] {
                let view = PopoverView(store: store)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let url = directory.appendingPathComponent("popover-\(scheme == .light ? "light" : "dark").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            exit(0)
        }
    }
}
