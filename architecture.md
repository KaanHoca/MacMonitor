# MacMonitor Architecture

MacMonitor is a native macOS desktop widget written in Swift/SwiftUI, built with plain `swiftc` (no Xcode project, no external dependencies). It shows live system metrics on the desktop and bundles a disk cleanup tool, fan control and memory cleanup.

## Source Layout

```
MacMonitor/
├── MacMonitor/
│   ├── MacMonitorApp.swift   # App entry, NSWindow and grid placement, menu bar,
│   │                         # launch at login, keep awake, menu bar text mode
│   ├── ContentView.swift     # SwiftUI views: gauge grid, process lists,
│   │                         # disk cleanup UI, thermals view, battery row
│   ├── Components.swift      # Shared UI: TickGauge, HistoryGraph,
│   │                         # DetailHeader, HistoryStore, UILayout constants
│   ├── WindowSnapper.swift   # Desktop widget grid geometry (pure CoreGraphics)
│   ├── WidgetChrome.swift    # Native corner mask and the per-state background view
│   ├── DesktopFocusRule.swift # When native widgets are full-color or dimmed (pure)
│   ├── WidgetAppearance.swift # Appearance and Widget Style choices, state tracking
│   ├── SystemMonitor.swift   # Metrics engine: CPU, RAM, disk, SMC temp/fans,
│   │                         # network, IPs, battery, GPU, alerts, purge, themes
│   ├── DiskCleaner.swift     # Disk cleanup engine: 19 categories, scan/clean,
│   │                         # safety allowlist, trash-safe categories
│   ├── FanHelper.swift       # Separate CLI binary: SMC fan control (run as admin)
│   ├── Info.plist            # LSUIElement app, bundle id com.local.MacMonitor
│   └── Resources/            # Generated app icon: Assets.car, MacMonitor.icns
├── design/                   # Icon artwork, Icon Composer document, make-icon.sh
├── Tests/
│   ├── WindowSnapperTests.swift     # Snapping tests with real display fixtures
│   ├── WidgetChromeTests.swift      # Corner mask against the native corner profile
│   └── DesktopFocusRuleTests.swift  # Focus rule against logged real clicks
├── build.sh                  # Terminal build
├── test.sh                   # Builds and runs the unit tests (plain swiftc)
├── Install and Run.command   # One-click build and launch
├── architecture.md           # This file
└── memory.md                 # Working log and decisions (Turkish)
```

## Runtime Topology

- `AppDelegate` owns a single `SystemMonitor` instance shared with `ContentView` (one metrics engine for the widget, the menu bar and the status item).
- The widget window is a borderless `NSWindow` at desktop icon level + 3 (one step above native desktop widgets) whose content view is a `WidgetBackgroundView` hosting the SwiftUI root. It snaps to the desktop widget grid and renders light, dark or glass like native widgets; see Widget Grid Placement and Widget Appearance.
- Launch order matters: the window is placed and every observer (moves, resize requests) is registered before the SwiftUI content is attached. Moving a window onto another display draws it immediately, so content attached earlier appeared and posted its first resize request before the resize observer existed (a detail view opened at launch then stayed at grid height).
- `SystemMonitor` ticks every 5 seconds on a main run loop timer registered in `.common` modes. Metric reads run on a background utility queue; results are delivered back with `publishOnMain`.

### publishOnMain (important)

`DispatchQueue.main.async` does not execute while an `NSMenu` tracks events, which froze menu bar stats. `publishOnMain` instead schedules blocks on the main `RunLoop` in `.common` modes and wakes the loop, so published values keep flowing while menus are open. All timers (tick, menu refresh, boost countdowns, status text) are likewise registered in `.common` modes.

### HistoryStore

Rolling 60-sample (5 minute) buffers for CPU, RAM, temperature, fan RPM and system power. It is a separate `ObservableObject` deliberately: the Thermals history graphs observe it directly, so per-tick appends do not invalidate the whole gauge grid. Published values on `SystemMonitor` still only change when the underlying value changes.

## UI Structure

- `ContentView` switches between the gauge grid and four detail modes (cpu, ram, disk, fan).
- Gauges are `TickGauge` dials: discrete radial tick marks drawn in one Canvas, lit up to the value with brightness ramping toward the tip. A single code path draws all four, so their geometry is pixel-identical by construction; there is deliberately no blur, shadow or hover scaling (out-of-phase glow animations previously made equal rings look unequal). Ticks turn orange past a warn threshold and red past a critical threshold (CPU/RAM 85/95%, disk 90/97%, temp 85/95°C).
- Hero transition: each dial and its detail header mini-dial share a `matchedGeometryEffect` id (`ring-cpu`, `ring-ram`, `ring-disk`, `ring-temp`) in one namespace. Tapping a gauge makes the dial fly into the header, where it stays live.
- Window size: the main view is a fixed 344x344 square, exactly a native macOS large widget, and detail views are 344x440. `ContentView` posts `.mmResizeWindow` only when switching between grid and detail; `AppDelegate.resizeWindow` animates the frame, keeping whichever vertical edge is nearer a screen edge fixed, and returning from a detail restores the exact grid frame. The hosting view runs with `sizingOptions = []` so SwiftUI's ideal content size can never override the window size (before this, a 4pt mismatch between the layout math and the content silently resized the window).
- The grid content fits the square with every row visible (16 + 100 + 18 + 100 + 21 + 72 + 16 = 343, constants in `UILayout`); hiding rows re-centers the content instead of resizing. Below the dials, three info rows (power, network speed, IP addresses) can each be shown or hidden from the menu bar's Widget Rows submenu (`widgetRow_power`/`widgetRow_network`/`widgetRow_ip` in UserDefaults, registered `true` by default); the power row also requires a readable SMC key (`monitor.systemPowerW > 0`). On portables the battery shares the power row (power keeps its natural width, the battery details take the rest), because a fourth row would not fit.
- Detail views add their own context row under the header: `ProcessListView` shows swap usage and memory pressure in the RAM detail, hidden entirely when `vm.swapusage` cannot be read; `DiskCleanupView` shows live read/write throughput, hidden until the first delta sample; `ThermalsView` adds a Power section (system, CPU and DC input wattage) with a `HistoryGraph` fed by `HistoryStore.power`.
- Dials are 100pt in two symmetric rows. Secondary info lives inside the dial as a small caption under the value: the disk dial shows free space (or the cleanable size after a scan), the temperature dial shows live fan RPM. Center text is capped to the dial's inner circle so it can never overlap the ticks.
- Accessibility: each gauge column is one accessibility element with a label; tooltips via `.help`; the breathing glow honors Reduce Motion.

## Widget Grid Placement

Native desktop widgets (macOS 14+) live on a grid that MacMonitor cannot join through WidgetKit, because WidgetKit refreshes are budgeted and on macOS 26 frequent reloads trigger heavy `chronod` disk writes, which rules out the live 5 second view. The window therefore mimics the grid instead.

- **Geometry** (measured on macOS 26): 180pt cells and 16pt gutters, so a large widget is 344x344 visible. Widget windows are one cell per unit and carry a transparent 8pt inset around the visible widget. Widgets keep a 16pt margin from screen edges and sit menu bar height + 16pt below the top, even on displays without a menu bar.
- **`WindowSnapper`** (pure, tested by `./test.sh`): given the dropped frame, the screen's frame and visible frame, the menu bar height and the native widget windows, it returns the nearest grid slot. The grid phase comes from a native widget on the same display when there is one; otherwise the grid hugs the screen edges nearest to the window. Slots covered by native widgets are skipped unless every slot is taken; a window that cannot fit is left unchanged.
- **Native widget discovery**: `CGWindowListCopyWindowInfo` windows owned by `com.apple.notificationcenterui` below normal window level. Bounds, owner and layer are readable without Screen Recording permission (verified from a standalone app with no grant; only window names are redacted), and the query runs only when a drag ends or at launch.
- **Drag detection**: a local event monitor marks a mouse-down on the widget; `didMove` while that mark is set starts a 50ms mouse-button poll that exists only for the duration of the drag. On release the window animates to the snapped slot and the slot is persisted. There is no steady-state timer.
- **Persistence rules**: only user drags write `windowX`/`windowY` (plus `windowOnGrid`). Moves made by macOS (display sleep, wake, rearrangement) are never saved; `didChangeScreenParametersNotification` puts the window back on its saved slot. If the saved display is not connected at launch, the widget shows on the main screen's default slot without overwriting the saved one. Positions saved before grid snapping existed, and the first launch, are snapped once and persisted, so the widget never re-flows on later launches. A drag during a detail view snaps when the view returns to grid size.
- **Level**: native widgets sit at desktop icon level + 2, MacMonitor at + 3, so a widget dropped onto MacMonitor's slot cannot cover it. macOS offers no way to reserve a slot, so it will still let you drop one there.
- **Lock Position** (menu, `windowLocked`): turns off `isMovableByWindowBackground`. Previously the whole widget was a drag handle and every tiny move was saved, which is how clicks on the dials drifted the window by a few points; snapping now absorbs such jitter anyway.

## Widget Appearance

The widget matches the native macOS 26 widgets next to it in their two states, full-color and dimmed glass, in Light and Dark. Every value below was measured from screen captures on the target Mac.

- **Menus**: Appearance (`appearanceMode`: `auto`, `light`, `dark`; Automatic follows the system including its day and night switch) and Widget Style (`widgetStyle`: `auto`, `fullColor`, `glass`; mirrors the macOS "Widget style" setting). `WidgetAppearance` persists both, resolves `isGlass` and the window's `NSAppearance`, and calls back so `AppDelegate` updates the window.
- **Backgrounds** (`WidgetBackgroundView`): full-color is an opaque surface, white in Light (native 1.00 vs ours 1.00) and sRGB 47 in Dark (native widgets read 61 in captures; sRGB 47 reads 61 through the same display pipeline, sRGB 61 read 78). Glass is `NSGlassEffectView` (`.clear`) that follows the window appearance: light glass in Light (0.40 vs native 0.39 over a dark wallpaper), dark glass plus a 45% black shade in Dark (26 to 30 vs native 24 to 27). Tinting the glass only lightened it. Before macOS 26 the HUD material stands in for glass. Hidden layers are removed from rendering.
- **Content**: colors go through `.primary` and per-state `ThemeColors` (Dark keeps the original palette, Light deepens it for contrast, Glass is white). In Glass the content is forced to the dark scheme so text is white, status and process colors turn white (heavy values stay brighter instead of red, since desaturated red became gray that vanished on light glass), the rest is desaturated, and a soft shadow keeps text legible over bright wallpaper. `AccentButtonChrome` gives the five accent buttons white labels on a tint in Dark and Glass and a tinted label in Light.
- **Corners**: 27.5pt continuous everywhere (`WidgetChrome.cornerMask`, tested against the measured native corner profile).
- **Native state rule** (`DesktopFocusRule`, pure and tested with logged clicks): native widgets follow the per-display "desktop revealed" state, not the frontmost app. Two observer runs that sampled a native widget pixel while the user clicked showed: a wallpaper click makes that display's widgets full-color; bringing parked windows back dims them; clicks on MacMonitor, on widgets or on other displays change nothing. No distributed or NSWorkspace notification announces the change.
- **Tracking** (Automatic style): a global left mouse-down monitor classifies clicks on the widget's display (wallpaper: full-color, app window: dimmed, Dock layer 18: re-check), app activations re-check visible app windows after 0.7s, and launch and display changes read the visible windows. Global monitors never see clicks on MacMonitor itself, which matches native widgets ignoring them. No polling; the monitor needs no permission. Known limit: transitions without a click or activation (a desktop shortcut, Mission Control) can lag until the next click; opening a new window while the desktop is revealed dims MacMonitor while native widgets stay full-color.
- **Cost**: measured back to back against the previous release under the same conditions, CPU was 1.79 to 1.85% vs 1.96 to 2.02% and memory 80 to 81 MB vs 79 MB; the glass effects measured within noise (1.88% vs 1.80% without them).

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
./test.sh    # unit tests
```

Both build scripts compile the app (SystemMonitor, DiskCleaner, Components, WindowSnapper, WidgetChrome, DesktopFocusRule, WidgetAppearance, ContentView, MacMonitorApp) with AppKit/SwiftUI/IOKit/ServiceManagement/UserNotifications, then FanHelper separately with IOKit only, and assemble `MacMonitor.app` with both binaries in `Contents/MacOS`. `test.sh` builds one temporary executable per suite (the code under test plus its test file, no XCTest): WindowSnapper, WidgetChrome and DesktopFocusRule; it exits non-zero on the first failing suite.

### App Icon

macOS 26 shrinks icons that do not fill its squircle onto a gray plate, and older systems never mask icons, so a full-bleed PNG cannot be used as is. `design/MacMonitor.icon` (Icon Composer; the artwork as one full-bleed layer, glass off, solid fill matching the artwork's background) is compiled by `design/make-icon.sh` with `actool` for a macOS 13.0 deployment target. That yields `Assets.car` (the macOS 26 icon plus classic squircle renditions for older systems, selected by `CFBundleIconName`) and a small `MacMonitor.icns` fallback (`CFBundleIconFile`). `actool` ships only with full Xcode, so the outputs live in `MacMonitor/Resources/` and the build scripts just copy them. The Photoshop source (`design/*.psd`) is git-ignored.

Dev hook: `open MacMonitor.app --args -debugDetail cpu|ram|disk|fan` opens a detail view directly (used for UI verification and screenshots).

## Known Constraints

- No code signing: local personal use; Gatekeeper only intervenes on quarantined copies.
- `#Preview` macros are not used because plain `swiftc` cannot compile them.
- UserNotifications requires the app to run from the bundle; permission is requested on first alert.
- The helper binary is user-writable and runs as admin via osascript; acceptable for personal use, a signed privileged helper (SMJobBless style) would be the hardened alternative.
