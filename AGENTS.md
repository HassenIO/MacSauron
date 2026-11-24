# AGENTS.md

MacSauron is a minimal macOS menu bar app (SwiftUI `MenuBarExtra` + Swift Charts) that shows CPU, memory, network and battery metrics.
It is a Swift Package with no Xcode project and no third-party dependencies.

## Commands

- Debug build: `swift build`
- Release app bundle: `./build.sh` (outputs `build/MacSauron.app`, ad-hoc signed, `LSUIElement` so there is no Dock icon)
- Run: `pkill -x MacSauron; open build/MacSauron.app`
- UI check without screen recording permission: `.build/debug/MacSauron --snapshot <dir>` writes `popover-light.png` and `popover-dark.png` to `<dir>` after 12s of sampling, then exits.
  AppKit controls (footer buttons) render as yellow placeholders there, which is expected.
- Idle CPU check: `ps -o time= -p $(pgrep -x MacSauron)` before and after a 60s wait, and `sample $(pgrep -x MacSauron) 10` to profile.

## Layout

All code lives in `Sources/MacSauron/`:

- `MacSauronApp.swift` - app entry, `MenuBarExtra` scene, menu bar label.
- `CPUMonitor.swift`, `MemoryMonitor.swift`, `NetworkMonitor.swift`, `BatteryMonitor.swift` - one reader per metric, built on Mach / sysctl / IOKit APIs (the same sources Activity Monitor uses, no `sudo`).
- `MetricsStore.swift` - `@MainActor @Observable` store, samples everything every 2s and keeps the histories.
- `PopoverView.swift` - the popover UI, one section view per metric.
- `WindowVisibilityReader.swift` - reports whether the popover window is on screen (occlusion state).
- `Format.swift` - number formatting helpers.
- `Snapshot.swift` - the `--snapshot` dev helper.

## Key design decisions

- `MenuBarExtra` keeps its window alive while hidden, so `onAppear` is not a visibility signal.
  The store samples into an `@ObservationIgnored` `live` buffer and only republishes `metrics` while `isPopoverVisible` is true.
  This keeps the hidden charts from re-rendering on every tick.
  Do not make views read live-updating state directly, except the menu bar label (`cpuTotal`).
- The visibility reader is attached in `MacSauronApp`, not inside `PopoverView`, so offscreen snapshots can render `PopoverView` alone.
- Battery history is persisted to `~/Library/Application Support/MacSauron/battery.json` (one reading per minute, 24h retention).
  On launch it is backfilled from `pmset -g log` charge entries, parsed off the main thread.
  The latest reading older than the 12h window is pinned to the window start so the graph spans the full chart.
- Memory definitions follow Activity Monitor: used = app + wired + compressed, app = internal - purgeable, cached = external + purgeable.
- Network uses `NET_RT_IFLIST2` 64-bit counters (the 32-bit `getifaddrs` counters wrap) and sums all non-loopback interfaces.

## Conventions

- Swift 6 language mode with strict concurrency; keep the build at zero warnings.
- Minimum target is macOS 14.
- Prefer public system APIs and no dependencies.
- Verify UI changes with `--snapshot` in both light and dark mode, and check idle CPU after changes to the store or views.
