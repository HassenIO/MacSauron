# AGENTS.md

MacSauron is a minimal macOS menu bar app (SwiftUI `MenuBarExtra` + Swift Charts) that shows CPU, memory, network, disk, battery and thermal metrics, plus the top 4 apps for CPU, memory, network and disk.
It is a Swift Package with no Xcode project and no third-party dependencies.

## Commands

- Debug build: `swift build`
- Release app bundle: `./build.sh` (outputs `build/MacSauron.app`, ad-hoc signed, `LSUIElement` so there is no Dock icon)
- Run: `pkill -x MacSauron; open build/MacSauron.app`
- UI check without screen recording permission: `.build/debug/MacSauron --snapshot <dir>` writes `popover-light.png` and `popover-dark.png` to `<dir>` after 15s of sampling (or `--snapshot <dir> <seconds>`), then exits.
  AppKit controls (footer buttons) render as yellow placeholders there, which is expected.
- Idle CPU check: `ps -o time= -p $(pgrep -x MacSauron)` before and after a 60s wait, and `sample $(pgrep -x MacSauron) 10` to profile.

## Layout

All code lives in `Sources/MacSauron/`:

- `MacSauronApp.swift` - app entry, `MenuBarExtra` scene, menu bar label.
- `CPUMonitor.swift`, `MemoryMonitor.swift`, `NetworkMonitor.swift`, `DiskMonitor.swift`, `BatteryMonitor.swift` - one reader per metric, built on Mach / sysctl / IOKit APIs (the same sources Activity Monitor uses, no `sudo`).
- `ProcessMonitor.swift` - per-app CPU, memory and disk IO via libproc (`proc_pid_rusage`), the 30s CPU warning window, plus `AppIdentity` (groups helper processes under their outermost `.app`).
- `ProcessNetworkMonitor.swift` - per-app network throughput from `nettop` runs.
- `MetricsStore.swift` - `@MainActor @Observable` store, samples everything every 2s and keeps the histories.
- `PopoverView.swift` - the popover UI: three two-column rows (CPU / Network, Memory / Disk, Battery / Thermal).
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
- Thermal: `ProcessInfo.thermalState`, recorded on change in memory only, over the 5-minute live window (keeping the change before it).
  macOS keeps no thermal history (`pmset -g log` has none), so a 12h axis next to the battery graph showed an invisible sliver after launch.
  It is not a temperature; sensor temperatures need private SMC / IOHID APIs, which this app avoids.
- `SectionHeader` has a fixed height so a taller symbol (the thermometer) does not shift one column against the other.
- Memory definitions follow Activity Monitor: used = app + wired + compressed, app = internal - purgeable, cached = external + purgeable.
- Memory pressure % is `100 - kern.memorystatus_level` (what Activity Monitor plots); the level (green / yellow / red) comes from `kern.memorystatus_vm_pressure_level`.
  The chart stacks one stepped area per level, with each sample counted only towards its own level, so each color is one seamless shape (per-sample bars showed antialiasing seams).
- Top apps: CPU % follows Activity Monitor (100% = one core), memory is the summed physical footprint.
  Without a privileged helper only processes owned by the current user are readable, so root daemons (WindowServer, kernel_task) are absent from the CPU and memory lists.
- An app averaging over 75% CPU across the last 15 samples (30s) is flagged and its icon becomes an orange warning triangle.
- Disk: system-wide rates from IOKit `IOBlockStorageDriver` "Statistics"; per-app rates from `ri_diskio_bytesread/written` in the same `proc_pid_rusage` call.
  Processes that exit between two samples are not counted.
- Throughput top lists drop apps under 1 KB/s (they would read "0 KB/s").
- `SectionRow` gives both sections of a row the same height and each section puts a `Spacer` before its top-apps list, so the lists line up.
- Per-process network has no public API: `nettop -P -L 1` runs back to back in a detached task (each run takes ~5s wall time but little CPU) and consecutive runs are diffed per pid.
  Never stream `nettop` or `top` (measured at ~120% and ~7% CPU).
- App icons are rasterized once into a small bitmap; raw `NSWorkspace` icons made `ImageRenderer` dim the whole snapshot.
- Network uses `NET_RT_IFLIST2` 64-bit counters (the 32-bit `getifaddrs` counters wrap) and sums all non-loopback interfaces.

## Conventions

- Swift 6 language mode with strict concurrency; keep the build at zero warnings.
- Minimum target is macOS 14.
- Prefer public system APIs and no dependencies.
- Verify UI changes with `--snapshot` in both light and dark mode, and check idle CPU after changes to the store or views.
