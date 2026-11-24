import SwiftUI

@main
struct MacSauronApp: App {
    @State private var store: MetricsStore

    init() {
        let store = MetricsStore()
        _store = State(initialValue: store)
        if let directory = Snapshot.outputDirectory {
            Snapshot.run(store: store, to: directory)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
                .background(WindowVisibilityReader { store.isPopoverVisible = $0 })
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let store: MetricsStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye")
            Text(store.cpuTotal.map(Format.percent) ?? "--")
                .monospacedDigit()
        }
    }
}
