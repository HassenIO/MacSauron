# MacSauron

A minimal macOS menu bar app that shows the key metrics of your Mac.
The menu bar shows the current CPU load.
Clicking it opens a popover with:

- CPU load graph (user / system, last 5 minutes)
- Memory breakdown (app, wired, compressed, cached, swap, memory pressure)
- Network throughput graph (received / sent, last 5 minutes)
- Battery level graph (last 12 hours)

All figures come from the same kernel and IOKit sources Activity Monitor uses.
No admin rights are needed.

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 6)

## Build and run

```bash
./build.sh
open build/MacSauron.app
```

To keep it, copy `build/MacSauron.app` to `/Applications`.
To start it at login, add it in System Settings > General > Login Items.

## Notes

- Battery history is stored in `~/Library/Application Support/MacSauron/battery.json` (one reading per minute).
- For periods when the app was not running, the battery graph is backfilled from the system power log (`pmset -g log`).
- Network totals include every non-loopback interface, so VPN traffic is counted on both the VPN and the physical interface.

## Development

`swift build` builds a debug binary.
`.build/debug/MacSauron --snapshot <dir>` renders the popover in light and dark mode to PNGs in `<dir>` after 12 seconds of sampling, then exits.
This is handy to check the UI without screen recording permission.
AppKit controls (the footer buttons) show as placeholders in those snapshots.
