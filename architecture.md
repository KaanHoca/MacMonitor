# MacMonitor Architecture

MacMonitor is a native macOS desktop widget written in Swift/SwiftUI, built with plain `swiftc` (no Xcode project, no external dependencies). It shows live system metrics on the desktop and bundles a disk cleanup tool, fan control and memory cleanup.

## Source Layout

```
MacMonitor/
├── MacMonitor/
│   ├── MacMonitorApp.swift   # App entry, NSWindow, menu bar, launch at login,
│   │                         # keep awake, menu bar text mode, window resizing
│   ├── ContentView.swift     # SwiftUI views: gauge grid, process lists,
│   │                         # disk cleanup UI, thermals view, battery row
│   ├── Components.swift      # Shared UI: RingGauge, Sparkline, HistoryGraph,
│   │                         # DetailHeader, HistoryStore, UILayout constants
│   ├── SystemMonitor.swift   # Metrics engine: CPU, RAM, disk, SMC temp/fans,
│   │                         # network, IPs, battery, GPU, alerts, purge, themes
│   ├── DiskCleaner.swift     # Disk cleanup engine: 19 categories, scan/clean,
│   │                         # safety allowlist, trash-safe categories
│   ├── FanHelper.swift       # Separate CLI binary: SMC fan control (run as admin)
│   └── Info.plist            # LSUIElement app, bundle id com.local.MacMonitor
├── build.sh                  # Terminal build
├── Install and Run.command   # One-click build and launch
├── architecture.md           # This file
└── memory.md                 # Working log and decisions (Turkish)
```

## Runtime Topology

- `AppDelegate` owns a single `SystemMonitor` instance shared with `ContentView` (one metrics engine for the widget, the menu bar and the status item).
- The widget window is a borderless `NSWindow` at desktop-icon level with an `NSVisualEffectView` (hudWindow material) and a rounded mask image. Position persists in UserDefaults.
- `SystemMonitor` ticks every 5 seconds on a main run loop timer registered in `.common` modes. Metric reads run on a background utility queue; results are delivered back with `publishOnMain`.

### publishOnMain (important)

`DispatchQueue.main.async` does not execute while an `NSMenu` tracks events, which froze menu bar stats. `publishOnMain` instead schedules blocks on the main `RunLoop` in `.common` modes and wakes the loop, so published values keep flowing while menus are open. All timers (tick, menu refresh, boost countdowns, status text) are likewise registered in `.common` modes.

### HistoryStore

Rolling 60-sample (5 minute) buffers for CPU, RAM, temperature and fan RPM. It is a separate `ObservableObject` deliberately: sparkline and graph views observe it directly, so per-tick appends do not invalidate the whole gauge grid. Published values on `SystemMonitor` still only change when the underlying value changes.

## UI Structure

- `ContentView` switches between the gauge grid and four detail modes (cpu, ram, disk, fan).
- Hero transition: each gauge ring and its detail header mini-ring share a `matchedGeometryEffect` id (`ring-cpu`, `ring-ram`, `ring-disk`, `ring-temp`) in one namespace. Tapping a gauge makes the ring fly into the header, where it stays live.
- Dynamic window height: `ContentView` posts `.mmResizeWindow` with the target height (340pt grid, 368pt with battery row, 440pt details, see `UILayout`); `AppDelegate.resizeWindow` animates the frame with the bottom edge anchored and clamps into the visible screen.
- Gauge columns pair an 80pt ring with a 14pt secondary slot: CPU/RAM sparklines, disk cleanable-size badge (after a scan), fan RPM label (or temp sparkline on fanless Macs).
- Accessibility: each gauge column is one accessibility element with a label; tooltips via `.help`; the breathing glow honors Reduce Motion.

## Metrics Sources

| Metric | Source |
|---|---|
| CPU | `host_processor_info`, 64-bit tick sums with wrap-safe deltas |
| RAM | `host_statistics64` (active + wired + compressor) |
| Disk | `FileManager.attributesOfFileSystem` |
| Temperature | SMC via IOKit; candidate keys probed once per launch (M1/M2/M3/M4 `Tp*/Te*/Tf*`, Intel `TC*`), EMA smoothing; 0 renders as `--` |
| Fans | SMC `FNum`, `F*Ac/Mn/Mx` |
| Network speed | `getifaddrs` byte deltas over `en*/bridge*` |
| Ping | `/sbin/ping -c 1` to 8.8.8.8, parsed |
| IPs | `getifaddrs` (local, en0 preferred) and `api.ipify.org` (external) |
| Battery | `IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` registry (cycles, health) |
| GPU | `IOAccelerator` PerformanceStatistics, read only while the menu is open |
| Processes | `/bin/ps` with `LC_ALL=C`, grouped by helper name, top 10 |

## Fan Boost Security Model

`FanHelper` is a separate binary compiled without app frameworks. `SystemMonitor.boostFans`:

1. Shell-quotes the helper path and escapes it for the AppleScript literal.
2. Runs it via `osascript ... with administrator privileges` with a trailing `&` and redirection, so osascript returns right after authentication instead of blocking for the 30s boost.
3. Starts the UI countdown and the 15-minute cooldown only when the exit status confirms authentication succeeded; a cancelled password prompt reverts cleanly.
4. The helper itself sleeps for the boost duration and always reverts fans to automatic, even if the app quits.

On Apple Silicon it sets the `FS!` force bits and writes `F*Tg` as float; on Intel it uses `F*Md` manual mode and `fpe2` encoding.

## Disk Cleanup Safety

- Path allowlist: deletions only under specific prefixes (user Library, caches, tmp, `Install macOS*` in /Applications, etc.); an explicit blocklist rejects dangerous roots.
- Categories marked `trashInstead` (macOS installers, incomplete downloads) are moved to the Trash via `FileManager.trashItem` and are never force-deleted on failure; the completion screen reports the recoverable portion separately.
- Toggle state persists in UserDefaults (`diskClean_` prefix); rows bind directly to the cleaner so Reset updates the UI immediately.
- Categories whose detector paths do not exist on the system are hidden.

## Alerts

`checkThresholds` runs each tick on the main thread: CPU at 100°C or disk 90% full posts a UserNotifications banner, at most once per hour per condition, toggleable from the menu (`alertsEnabled`, default on). Requests authorization lazily on first alert.

## Build

```
./build.sh   # or double-click "Install and Run.command"
```

Both scripts compile the app (SystemMonitor, DiskCleaner, Components, ContentView, MacMonitorApp) with AppKit/SwiftUI/IOKit/ServiceManagement/UserNotifications, then FanHelper separately with IOKit only, and assemble `MacMonitor.app` with both binaries in `Contents/MacOS`.

Dev hook: `open MacMonitor.app --args -debugDetail cpu|ram|disk|fan` opens a detail view directly (used for UI verification and screenshots).

## Known Constraints

- No code signing: local personal use; Gatekeeper only intervenes on quarantined copies.
- `#Preview` macros are not used because plain `swiftc` cannot compile them.
- UserNotifications requires the app to run from the bundle; permission is requested on first alert.
- The helper binary is user-writable and runs as admin via osascript; acceptable for personal use, a signed privileged helper (SMJobBless style) would be the hardened alternative.
