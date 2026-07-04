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
│   ├── Components.swift      # Shared UI: TickGauge, HistoryGraph,
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

Rolling 60-sample (5 minute) buffers for CPU, RAM, temperature, fan RPM and system power. It is a separate `ObservableObject` deliberately: the Thermals history graphs observe it directly, so per-tick appends do not invalidate the whole gauge grid. Published values on `SystemMonitor` still only change when the underlying value changes.

## UI Structure

- `ContentView` switches between the gauge grid and four detail modes (cpu, ram, disk, fan).
- Gauges are `TickGauge` dials: discrete radial tick marks drawn in one Canvas, lit up to the value with brightness ramping toward the tip. A single code path draws all four, so their geometry is pixel-identical by construction; there is deliberately no blur, shadow or hover scaling (out-of-phase glow animations previously made equal rings look unequal). Ticks turn orange past a warn threshold and red past a critical threshold (CPU/RAM 85/95%, disk 90/97%, temp 85/95°C).
- Hero transition: each dial and its detail header mini-dial share a `matchedGeometryEffect` id (`ring-cpu`, `ring-ram`, `ring-disk`, `ring-temp`) in one namespace. Tapping a gauge makes the dial fly into the header, where it stays live.
- Dynamic window height: `ContentView` posts `.mmResizeWindow` with a target height from `UILayout.mainHeight(hasBattery:showPower:showNetwork:showIP:)`, which adds the fixed grid base to the height of every currently visible info row (`powerRowHeight`/`networkRowHeight`/`ipRowHeight`/`batteryRowHeight`, each separated by `infoRowSpacing`); detail views use a fixed 440pt. `AppDelegate.resizeWindow` animates the frame with the bottom edge anchored and clamps into the visible screen.
- Below the grid, three info rows (power, network speed, IP addresses) can each be shown or hidden independently from the menu bar's Widget Rows submenu (`widgetRow_power`/`widgetRow_network`/`widgetRow_ip` in UserDefaults, registered `true` by default); the power row also requires a readable SMC key (`monitor.systemPowerW > 0`), so it stays hidden on Macs where none of the candidate keys exist.
- Detail views add their own context row under the header: `ProcessListView` shows swap usage and memory pressure in the RAM detail, hidden entirely when `vm.swapusage` cannot be read; `DiskCleanupView` shows live read/write throughput, hidden until the first delta sample; `ThermalsView` adds a Power section (system, CPU and DC input wattage) with a `HistoryGraph` fed by `HistoryStore.power`.
- Dials are 100pt in two symmetric rows. Secondary info lives inside the dial as a small caption under the value: the disk dial shows free space (or the cleanable size after a scan), the temperature dial shows live fan RPM. Center text is capped to the dial's inner circle so it can never overlap the ticks.
- Accessibility: each gauge column is one accessibility element with a label; tooltips via `.help`; the breathing glow honors Reduce Motion.

## Metrics Sources

| Metric | Source |
|---|---|
| CPU | `host_processor_info`, 64-bit tick sums with wrap-safe deltas |
| RAM | `host_statistics64` (active + wired + compressor) |
| Swap | `sysctl vm.swapusage` (used/total, GB); `-1` total means the sysctl is unavailable and the row stays hidden |
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` (0 unknown, 1 normal, 2 warning, 4 critical) |
| Disk | `FileManager.attributesOfFileSystem` |
| Disk I/O | `IOBlockStorageDriver` "Statistics" property, byte deltas between ticks; the real keys are `Bytes (Read)` and `Bytes (Write)` (not "Bytes (Written)") |
| Temperature | SMC via IOKit; candidate keys probed once per launch (M1/M2/M3/M4 `Tp*/Te*/Tf*`, Intel `TC*`), EMA smoothing; 0 renders as `--` |
| Fans | SMC `FNum`, `F*Ac/Mn/Mx` |
| Power | SMC via IOKit; system total `PSTR`, CPU package `PHPC`, DC input `PDTR` (fallback `PD0R`), each probed once per launch from a candidate list like the temperature keys; availability is cached in `powerKeyAvailable` and the reading hides everywhere once no candidate resolves |
| Network speed | `getifaddrs` byte deltas over `en*/bridge*` |
| Ping | `/sbin/ping -c 1` to 8.8.8.8, parsed |
| IPs | `getifaddrs` (local, en0 preferred) and `api.ipify.org` (external) |
| Battery | `IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` registry (cycles, health) |
| GPU | `IOAccelerator` PerformanceStatistics, read only while the menu is open |
| Processes | `/bin/ps` with `LC_ALL=C`, grouped by helper name, top 10 |

## Fan Boost Security Model

`FanHelper` is a separate binary compiled without app frameworks. `SystemMonitor.boostFans`:

1. Shell-quotes the helper path and escapes it for the AppleScript literal.
2. Runs it via `osascript ... with administrator privileges` with a trailing `&` and redirection, so osascript returns right after authentication instead of blocking for the boost cycle.
3. Starts the UI countdown only when the exit status confirms authentication succeeded; a cancelled password prompt reverts cleanly.
4. Tracks the peak RPM during the cycle; if the fans never sped up, the button reports "No effect".

Helper behavior (`boost <percent> <duration>`): SMC keys are introspected rather than guessed by architecture. Manual mode uses the per-fan `F*Md` key where present (modern Apple Silicon such as M4 has no `FS!` force-bits key) with `FS!` as fallback; targets are written in the encoding the SMC reports (`flt` or `fpe2`). Each fan's target is `percent` into its own min-max band, hard-capped at 90% of its absolute max. The cycle ramps up with smoothstep easing (up to 6s), holds, ramps down (up to 10s), then returns control to the automatic thermal controller. SIGINT/SIGTERM/SIGHUP handlers always revert to automatic mode, so fans can never stay stuck in manual control.

The duration is user-selectable in the Thermals view (15/30/45/60/120s, persisted as `boostDuration`). There is deliberately no cooldown between boosts: the admin prompt on every run is the rate limiter, and sustained high fan speed is within the hardware's design envelope.

## Disk Cleanup Safety

- Path allowlist: deletions only under specific prefixes (user Library, caches, tmp, `Install macOS*` in /Applications, etc.); an explicit blocklist rejects dangerous roots.
- Categories marked `trashInstead` (macOS installers, incomplete downloads) are moved to the Trash via `FileManager.trashItem` and are never force-deleted on failure; the completion screen reports the recoverable portion separately.
- Toggle state persists in UserDefaults (`diskClean_` prefix); rows bind directly to the cleaner so Reset updates the UI immediately.
- Categories whose detector paths do not exist on the system are hidden.

## Alerts

`checkThresholds` runs each tick on the main thread: CPU at 100°C or disk 90% full posts a UserNotifications banner, at most once per hour per condition, toggleable from the menu (`alertsEnabled`, default on). Requests authorization lazily on first alert.

## Menu Bar

The status item's dropdown mirrors the widget's live metrics (CPU, Memory, Disk, Temp, Fan, Power, GPU, uptime, load average), refreshed only while the menu is open via `publishOnMain`. The Power line reads `systemPowerW` and hides itself when the SMC has no readable power key. A Widget Rows submenu lets the power, network speed and IP address info rows be shown or hidden independently; the choices are stored under `widgetRow_power`/`widgetRow_network`/`widgetRow_ip` and registered as `true` in `applicationDidFinishLaunching` via `UserDefaults.register(defaults:)`, so upgrades keep every row visible until the user opts out.

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
