# Power Metrics, Extra Stats and Widget Row Toggles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live watts (system power) to the widget and menu, a power breakdown and history graph to Thermals, swap and memory pressure to the RAM detail, disk read/write speed to the Disk detail, and a "Widget Rows" menu that shows or hides the power, network speed, and IP rows.

**Architecture:** All power values come from the existing SMC layer in SystemMonitor (candidate-key discovery, exactly like temperature keys). Swap and pressure come from sysctl, disk I/O from IOBlockStorageDriver statistics. Row visibility flags live in UserDefaults; the menu writes them, ContentView reads them via @AppStorage, and the window height becomes a function of the visible rows.

**Tech Stack:** Swift / SwiftUI / AppKit / IOKit, built with `./build.sh` (swiftc, no Xcode project).

**Spec:** `docs/superpowers/specs/2026-07-04-power-metrics-design.md`

## Global Constraints

- No test framework exists in this repo (swiftc-only). Each task replaces unit tests with: compile via `./build.sh`, relaunch the app, observe runtime behavior (screenshot or command output). Never claim success without running the verification commands.
- SourceKit/editor diagnostics are false positives here (cross-file symbols); `./build.sh` output is the only truth.
- macOS 13.0+ target, Apple Silicon + Intel. Anything hardware-specific must degrade honestly: if a value cannot be read, hide its row. Never show fake or frozen values.
- ALL @Published writes go through `publishOnMain` (never `DispatchQueue.main.async`). All timers already run in `.common` mode; do not change that.
- In SwiftUI `Text`, numbers must be produced with `String(format:)` (raw Int interpolation applies Turkish locale grouping).
- Counters summed across ticks use `UInt64` with wrap/negative-delta protection.
- Code and comments in English. UI copy in English. No em/en dashes anywhere.
- Commit after every task with a descriptive English sentence ending in a period. NO Claude/Co-Authored-By attribution in commits (repo rule).
- Bundle id (for `defaults` commands): `com.local.MacMonitor`. Process name: `MacMonitor`.
- Scratchpad for screenshots and temp files: use the session scratchpad directory, referred to below as `$SCRATCH`.
- The window id + screenshot pattern used in every visual check:

```bash
killall MacMonitor 2>/dev/null; sleep 1; open /Users/karcael/Desktop/MacMonitor/MacMonitor.app; sleep 6
WINID=$(swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "MacMonitor" {
    print(w["kCGWindowNumber"] as! Int)
    break
}
EOF
)
screencapture -x -o -l "$WINID" "$SCRATCH/shot.png"
```

Then Read the png. The widget is desktop-level, so only the `-l <id>` capture works; region capture grabs overlapping apps.

---

### Task 1: Power data layer in SystemMonitor and HistoryStore

**Files:**
- Modify: `MacMonitor/SystemMonitor.swift` (published block ~line 94, `update(diskToo:)` ~lines 222-272, new Power section after `getTemp()` ~line 964)
- Modify: `MacMonitor/Components.swift` (HistoryStore ~lines 85-109)

**Interfaces:**
- Consumes: existing `readSMCValue(_ key: String) -> Double?`, `publishOnMain`, `HistoryStore.append`.
- Produces: `@Published var systemPowerW: Double` (0 = unavailable), `@Published var cpuPowerW: Double`, `@Published var dcInPowerW: Double` on SystemMonitor; `HistoryStore.power: [Double]`; new `HistoryStore.append(cpu:ram:temp:fans:power:)` signature; UserDefaults key `powerKeyAvailable: Bool` written after probe. Later tasks rely on exactly these names.

- [ ] **Step 1: Add published power properties**

In `MacMonitor/SystemMonitor.swift`, directly after `@Published var cpuTemp: Double = 0` (line 94), add:

```swift
    @Published var systemPowerW: Double = 0   // watts, 0 = no readable power key
    @Published var cpuPowerW: Double = 0      // CPU package watts (Thermals breakdown)
    @Published var dcInPowerW: Double = 0     // DC input watts (Thermals breakdown)
```

- [ ] **Step 2: Add the power reading section**

After the closing brace of `getTemp()` (line 964, just before `// MARK: - Fan Reading`), add:

```swift
    // MARK: - Power (SMC)
    // Candidate keys per slot, discovered once at launch like temperature
    // keys. Verified by SMC probe on an M4 Mac mini: PSTR (system total),
    // PHPC (CPU package), PDTR and PD0R (DC input). Missing keys simply
    // leave their published value at 0 and the UI hides the row.
    private static let systemPowerCandidates = ["PSTR"]
    private static let cpuPowerCandidates = ["PHPC"]
    private static let dcInPowerCandidates = ["PDTR", "PD0R"]
    private var powerKeysProbed = false
    private var systemPowerKey: String?
    private var cpuPowerKey: String?
    private var dcInPowerKey: String?

    // Power-specific SMC read with plausibility validation
    private func readSMCPower(_ key: String) -> Double? {
        guard let val = readSMCValue(key) else { return nil }
        return (val >= 0 && val < 1000) ? val : nil
    }

    private func getPower() -> (system: Double, cpu: Double, dcIn: Double) {
        if !powerKeysProbed {
            powerKeysProbed = true
            systemPowerKey = Self.systemPowerCandidates.first { readSMCPower($0) != nil }
            cpuPowerKey = Self.cpuPowerCandidates.first { readSMCPower($0) != nil }
            dcInPowerKey = Self.dcInPowerCandidates.first { readSMCPower($0) != nil }
            // Cache availability so the next launch can size the window
            // correctly before the first async tick publishes a value.
            UserDefaults.standard.set(systemPowerKey != nil, forKey: "powerKeyAvailable")
        }
        let system = systemPowerKey.flatMap { readSMCPower($0) } ?? 0
        let cpu = cpuPowerKey.flatMap { readSMCPower($0) } ?? 0
        let dcIn = dcInPowerKey.flatMap { readSMCPower($0) } ?? 0
        return (system, cpu, dcIn)
    }
```

- [ ] **Step 3: Read and publish power in the tick**

In `update(diskToo:)`, after `let fanData = self.getFans()` (line 229), add:

```swift
            let power = self.getPower()
```

Inside the `publishOnMain` block, after the `cpuTemp` update (line 252), add:

```swift
                let roundedPower = (power.system * 10).rounded() / 10
                if self.systemPowerW != roundedPower { self.systemPowerW = roundedPower }
                let roundedCPUPower = (power.cpu * 10).rounded() / 10
                if self.cpuPowerW != roundedCPUPower { self.cpuPowerW = roundedCPUPower }
                let roundedDCIn = (power.dcIn * 10).rounded() / 10
                if self.dcInPowerW != roundedDCIn { self.dcInPowerW = roundedDCIn }
```

Change the `history.append` call (lines 262-267) to:

```swift
                self.history.append(
                    cpu: roundedCPU,
                    ram: roundedUsed,
                    temp: roundedTemp,
                    fans: fanData.map { $0.actualRPM },
                    power: roundedPower
                )
```

- [ ] **Step 4: Add the power buffer to HistoryStore**

In `MacMonitor/Components.swift`, add to HistoryStore's published block (after `fanRPM`, line 91):

```swift
    @Published private(set) var power: [Double] = []
```

Change `append` (line 93) to take the extra parameter and store it:

```swift
    func append(cpu: Double, ram: Double, temp: Double, fans: [Double], power: Double) {
        appendValue(&self.cpu, cpu)
        appendValue(&self.ram, ram)
        if temp > 0 { appendValue(&self.temp, temp) }
        if power > 0 { appendValue(&self.power, power) }
        if !fans.isEmpty {
            if fanRPM.count != fans.count { fanRPM = fans.map { _ in [] } }
            for (i, rpm) in fans.enumerated() {
                appendValue(&fanRPM[i], rpm)
            }
        }
    }
```

- [ ] **Step 5: Build**

Run: `cd /Users/karcael/Desktop/MacMonitor && ./build.sh`
Expected: "MacMonitor.app is ready!" with no compiler errors.

- [ ] **Step 6: Cross-check the source value**

The scratchpad probe from the design phase (`$SCRATCH/powerprobe.swift`) prints live SMC values. Run `swift $SCRATCH/powerprobe.swift | grep -E "PSTR|PHPC|PDTR"` and note the PSTR value; the widget row added in Task 2 must show a value in the same range (a few watts of drift is normal).
Expected: three lines with plausible watt values (PSTR roughly 10-30 W idle on the M4 mini).

- [ ] **Step 7: Commit**

```bash
git add MacMonitor/SystemMonitor.swift MacMonitor/Components.swift
git commit -m "Read system, CPU package and DC input power from the SMC with key discovery."
```

---

### Task 2: Widget power row, row visibility flags and dynamic height

**Files:**
- Modify: `MacMonitor/Components.swift` (UILayout, lines 5-12)
- Modify: `MacMonitor/ContentView.swift` (ContentView state ~line 10, `onChange` ~lines 93-102, info rows ~lines 252-351, helpers after `batteryIcon`)
- Modify: `MacMonitor/MacMonitorApp.swift` (`applicationDidFinishLaunching`, lines 47-51)

**Interfaces:**
- Consumes: `monitor.systemPowerW` (Task 1), UserDefaults key `powerKeyAvailable` (Task 1).
- Produces: `UILayout.mainHeight(hasBattery:showPower:showNetwork:showIP:) -> CGFloat` (the old `mainHeight(hasBattery:)` is REMOVED); UserDefaults keys `widgetRow_power`, `widgetRow_network`, `widgetRow_ip` (Bool, registered default true). Task 3's menu writes these same keys.

- [ ] **Step 1: Rework UILayout**

Replace the whole `UILayout` enum in `MacMonitor/Components.swift` (lines 5-12) with:

```swift
enum UILayout {
    static let width: CGFloat = 300
    static let detailHeight: CGFloat = 440

    // Grid section: 20 top padding + two 100pt dial rows with 24 spacing
    // + separator block (1pt line with 12pt vertical padding) + 20 bottom
    // padding, plus the small slack the original 340pt window carried.
    static let gridBase: CGFloat = 293
    static let infoRowSpacing: CGFloat = 10
    static let powerRowHeight: CGFloat = 14
    static let networkRowHeight: CGFloat = 14
    static let ipRowHeight: CGFloat = 24
    static let batteryRowHeight: CGFloat = 14

    static func mainHeight(hasBattery: Bool, showPower: Bool, showNetwork: Bool, showIP: Bool) -> CGFloat {
        var rows: [CGFloat] = []
        if showPower { rows.append(powerRowHeight) }
        if showNetwork { rows.append(networkRowHeight) }
        if showIP { rows.append(ipRowHeight) }
        if hasBattery { rows.append(batteryRowHeight) }
        guard !rows.isEmpty else { return gridBase }
        return gridBase + rows.reduce(0, +) + CGFloat(rows.count - 1) * infoRowSpacing
    }
}
```

- [ ] **Step 2: Add row flags and height helpers to ContentView**

In `MacMonitor/ContentView.swift`, after `@Namespace private var ringNS` (line 11), add:

```swift
    @AppStorage("widgetRow_power") private var showPowerRow = true
    @AppStorage("widgetRow_network") private var showNetworkRow = true
    @AppStorage("widgetRow_ip") private var showIPRow = true
```

After `closeDetail()` (line 135), add:

```swift
    // The power row needs both the user toggle and actual data; on Macs
    // without a readable power key the row never appears.
    private var powerRowVisible: Bool { showPowerRow && monitor.systemPowerW > 0 }

    private var currentMainHeight: CGFloat {
        UILayout.mainHeight(
            hasBattery: monitor.batteryPresent,
            showPower: powerRowVisible,
            showNetwork: showNetworkRow,
            showIP: showIPRow
        )
    }
```

- [ ] **Step 3: Route all grid heights through currentMainHeight**

Replace the existing `.onChange(of: detail)` block (lines 93-102) with:

```swift
        .onChange(of: detail) { newDetail in
            let isDetail = newDetail != .none
            let height = isDetail ? UILayout.detailHeight : currentMainHeight
            NotificationCenter.default.post(
                name: .mmResizeWindow, object: nil,
                userInfo: ["height": height, "isDetail": isDetail]
            )
        }
        .onChange(of: currentMainHeight) { newHeight in
            // Row toggles and late power discovery resize the grid live
            guard detail == .none else { return }
            NotificationCenter.default.post(
                name: .mmResizeWindow, object: nil,
                userInfo: ["height": newHeight, "isDetail": false]
            )
        }
```

- [ ] **Step 4: Restructure the info rows**

In `gaugeGrid`, replace everything from `// Network stats row` (line 259) to the end of the battery row block (line 351, keep the closing `}` of the outer VStack and `.padding(20)`) with:

```swift
            // Info rows below the separator. Each row can be hidden from
            // the menu bar "Widget Rows" submenu; fixed heights keep the
            // window height math in UILayout.mainHeight exact.
            VStack(spacing: UILayout.infoRowSpacing) {
                if powerRowVisible {
                    powerRow.frame(height: UILayout.powerRowHeight)
                }
                if showNetworkRow {
                    networkStatsRow.frame(height: UILayout.networkRowHeight)
                }
                if showIPRow {
                    ipRow.frame(height: UILayout.ipRowHeight)
                }
                if monitor.batteryPresent {
                    batteryRow.frame(height: UILayout.batteryRowHeight)
                }
            }
```

Then, after the `batteryIcon` computed property (around line 356), add the four row views. `networkStatsRow`, `ipRow` and `batteryRow` are the EXACT code blocks removed above (network row content lines 260-291 without the trailing padding change, IP row lines 296-309, battery row HStack lines 314-350 without the leading `Spacer().frame(height: 8)`), each ending with its original `.padding(.horizontal, 4)`. The only new view is:

```swift
    private var powerRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundStyle(tc.accent.opacity(0.6))
            Text(String(format: "%.1f W", monitor.systemPowerW))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .help("System power consumption")
        .accessibilityLabel(String(format: "Power %.1f watts", monitor.systemPowerW))
    }
```

- [ ] **Step 5: Register defaults and fix the initial window height**

In `MacMonitor/MacMonitorApp.swift`, `applicationDidFinishLaunching`, add as the FIRST line of the method body:

```swift
        UserDefaults.standard.register(defaults: [
            "widgetRow_power": true,
            "widgetRow_network": true,
            "widgetRow_ip": true
        ])
```

Replace the `let size = ...` line (line 51) with:

```swift
        let d = UserDefaults.standard
        let size = NSSize(width: UILayout.width, height: UILayout.mainHeight(
            hasBattery: monitor.batteryPresent,
            showPower: d.bool(forKey: "powerKeyAvailable") && d.bool(forKey: "widgetRow_power"),
            showNetwork: d.bool(forKey: "widgetRow_network"),
            showIP: d.bool(forKey: "widgetRow_ip")
        ))
```

- [ ] **Step 6: Build**

Run: `cd /Users/karcael/Desktop/MacMonitor && ./build.sh`
Expected: clean build. If `mainHeight(hasBattery:)` is still referenced anywhere, the compiler will point at it; update that call site to the new signature.

- [ ] **Step 7: Visual check, all rows on**

Use the screenshot pattern from Global Constraints. Read the png.
Expected: power row (bolt icon + "NN.N W") above the network row, value close to the Task 1 PSTR reading; no clipped content; no excess empty space at the bottom. If spacing is off, tune `UILayout.gridBase` by a few points and rebuild.

- [ ] **Step 8: Verify each toggle flag**

```bash
defaults write com.local.MacMonitor widgetRow_network -bool false
killall MacMonitor; sleep 1; open MacMonitor.app; sleep 6
# screenshot again
```
Expected: network speed row gone, window shorter, position not drifted. Repeat once for `widgetRow_ip` and `widgetRow_power`, then restore:

```bash
defaults write com.local.MacMonitor widgetRow_network -bool true
defaults write com.local.MacMonitor widgetRow_ip -bool true
defaults write com.local.MacMonitor widgetRow_power -bool true
```

- [ ] **Step 9: Verify detail round trip**

Run: `killall MacMonitor; sleep 1; open MacMonitor.app --args -debugDetail cpu -debugReturnAfter 5`, wait 12 s, screenshot.
Expected: widget back at grid height in its original position (regression guard for the drift bug).

- [ ] **Step 10: Commit**

```bash
git add MacMonitor/Components.swift MacMonitor/ContentView.swift MacMonitor/MacMonitorApp.swift
git commit -m "Add a live power row to the widget and make info rows toggleable with dynamic height."
```

---

### Task 3: Menu Power line and Widget Rows submenu

**Files:**
- Modify: `MacMonitor/MacMonitorApp.swift` (menu item ivars ~line 28, `setupStatusBar` lines 234-267, `updateMenuStats` lines 314-347, actions section)

**Interfaces:**
- Consumes: `monitor.systemPowerW` (Task 1), UserDefaults keys `widgetRow_*` (Task 2). ContentView reacts to the key writes automatically through @AppStorage; no notification is needed.
- Produces: menu UI only, nothing consumed by later tasks.

- [ ] **Step 1: Add menu item ivars**

After `private var loadMenuItem: NSMenuItem!` (line 28), add:

```swift
    private var powerMenuItem: NSMenuItem!
    private var widgetRowPowerItem: NSMenuItem!
    private var widgetRowNetworkItem: NSMenuItem!
    private var widgetRowIPItem: NSMenuItem!
```

- [ ] **Step 2: Create and insert the Power stats line**

In `setupStatusBar`, after `fanMenuItem = makeStatsItem("fan.fill", "Fan", "—")` (line 238), add:

```swift
        powerMenuItem = makeStatsItem("bolt.fill", "Power", "—")
```

And after `menu.addItem(fanMenuItem)` (line 247), add:

```swift
        menu.addItem(powerMenuItem)
```

- [ ] **Step 3: Add the Widget Rows submenu**

In `setupStatusBar`, directly after `menu.addItem(themeItem)` (line 267), add:

```swift
        // Widget Rows submenu: shows or hides individual widget info rows
        let widgetRowsItem = NSMenuItem(title: "Widget Rows", action: nil, keyEquivalent: "")
        widgetRowsItem.image = NSImage(systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: "Widget Rows")
        widgetRowsItem.image?.size = NSSize(width: 14, height: 14)
        let rowsMenu = NSMenu()
        widgetRowPowerItem = makeWidgetRowItem("Power", key: "widgetRow_power")
        widgetRowNetworkItem = makeWidgetRowItem("Network Speed", key: "widgetRow_network")
        widgetRowIPItem = makeWidgetRowItem("IP Addresses", key: "widgetRow_ip")
        rowsMenu.addItem(widgetRowPowerItem)
        rowsMenu.addItem(widgetRowNetworkItem)
        rowsMenu.addItem(widgetRowIPItem)
        widgetRowsItem.submenu = rowsMenu
        menu.addItem(widgetRowsItem)
```

- [ ] **Step 4: Add the helper and the toggle action**

After `makeStatsItem` (line 312), add:

```swift
    private func makeWidgetRowItem(_ title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleWidgetRow(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        return item
    }
```

In the `// MARK: - Actions` section (after `toggleAlerts`), add:

```swift
    @objc private func toggleWidgetRow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let newValue = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newValue, forKey: key)
        sender.state = newValue ? .on : .off
    }
```

- [ ] **Step 5: Update the stats line and hide items without data**

In `updateMenuStats`, after the fan block (line 336), add:

```swift
        if monitor.systemPowerW > 0 {
            powerMenuItem.isHidden = false
            powerMenuItem.title = String(format: "Power:  %.1f W", monitor.systemPowerW)
        } else {
            powerMenuItem.isHidden = true
        }
        // No power data means the toggle would be a no-op; hide it too
        widgetRowPowerItem.isHidden = monitor.systemPowerW <= 0
```

- [ ] **Step 6: Build and launch**

Run: `cd /Users/karcael/Desktop/MacMonitor && ./build.sh && killall MacMonitor 2>/dev/null; sleep 1; open MacMonitor.app`
Expected: clean build, app running.

- [ ] **Step 7: Verify the toggle round trip through defaults**

NSMenu clicks cannot be automated without accessibility permissions, so verify the persistence path and ask the user to click once:

```bash
defaults read com.local.MacMonitor widgetRow_network
```
Expected: `1`. Then tell the user (in Turkish): open the menu bar icon, check that "Power: NN.N W" is listed and that Widget Rows > Network Speed unchecks and the row disappears immediately, then re-check it. Wait for confirmation before committing.

- [ ] **Step 8: Commit**

```bash
git add MacMonitor/MacMonitorApp.swift
git commit -m "Add a Power line and a Widget Rows visibility submenu to the status bar menu."
```

---

### Task 4: Power section in Thermals

**Files:**
- Modify: `MacMonitor/ContentView.swift` (ThermalsView call site lines 73-88, ThermalsView struct ~lines 777-887)

**Interfaces:**
- Consumes: `monitor.systemPowerW`, `monitor.cpuPowerW`, `monitor.dcInPowerW`, `history.power` (Task 1).
- Produces: UI only.

- [ ] **Step 1: Add parameters to ThermalsView**

In the ThermalsView struct, after `let currentTemp: Double` (line 782), add:

```swift
    let systemPowerW: Double
    let cpuPowerW: Double
    let dcInPowerW: Double
```

- [ ] **Step 2: Pass the values at the call site**

In ContentView's `case .fan:` (lines 74-87), after `currentTemp: monitor.cpuTemp,`, add:

```swift
                    systemPowerW: monitor.systemPowerW,
                    cpuPowerW: monitor.cpuPowerW,
                    dcInPowerW: monitor.dcInPowerW,
```

- [ ] **Step 3: Render the power section**

In ThermalsView's body, inside the ScrollView VStack, directly after the temperature history if/else block (after line 837's closing brace) and before `if fans.isEmpty`, add:

```swift
                    if systemPowerW > 0 {
                        sectionLabel("POWER")
                            .padding(.top, 4)
                        HStack(spacing: 0) {
                            powerStat("System", systemPowerW)
                            if cpuPowerW > 0 { powerStat("CPU", cpuPowerW) }
                            if dcInPowerW > 0 { powerStat("DC In", dcInPowerW) }
                        }
                        if history.power.count > 1 {
                            HistoryGraph(series: [history.power], maxValue: 0, color: accent)
                                .frame(height: 56)
                            HStack {
                                Text(String(format: "min %.1f W", history.power.min() ?? 0))
                                Spacer()
                                Text(String(format: "max %.1f W", history.power.max() ?? 0))
                            }
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                        }
                    }
```

- [ ] **Step 4: Add the powerStat helper**

After `sectionLabel` (line 887), add:

```swift
    private func powerStat(_ label: String, _ watts: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1f W", watts))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
    }
```

- [ ] **Step 5: Build and verify visually**

Run: `cd /Users/karcael/Desktop/MacMonitor && ./build.sh && killall MacMonitor 2>/dev/null; sleep 1; open MacMonitor.app --args -debugDetail fan`, wait 15 s (so the history graph has at least two samples), screenshot, Read it.
Expected: POWER section with three plausible watt values and a short history line; temperature and fan sections intact below it.

- [ ] **Step 6: Commit**

```bash
git add MacMonitor/ContentView.swift
git commit -m "Show a power breakdown and history graph in the Thermals detail."
```

---

### Task 5: Swap and memory pressure in the RAM detail

**Files:**
- Modify: `MacMonitor/SystemMonitor.swift` (published block, `update(diskToo:)`, new functions after `getRAM` section ~line 336)
- Modify: `MacMonitor/ContentView.swift` (ProcessListView struct ~lines 427-503, RAM call site lines 22-42, helpers)

**Interfaces:**
- Consumes: `publishOnMain`, `update(diskToo:)` background block.
- Produces: `@Published var swapUsedGB: Double` (default 0), `@Published var swapTotalGB: Double` (default -1, -1 = unknown/hide), `@Published var memoryPressureLevel: Int` (0 unknown, 1 normal, 2 warning, 4 critical); ProcessListView optional params `infoIcon`, `infoText`, `infoDetail`, `infoDetailColor`.

- [ ] **Step 1: Add published properties**

In `MacMonitor/SystemMonitor.swift`, after the power properties added in Task 1, add:

```swift
    @Published var swapUsedGB: Double = 0
    @Published var swapTotalGB: Double = -1   // -1 = sysctl unavailable, hide row
    @Published var memoryPressureLevel: Int = 0  // 0 unknown, 1 normal, 2 warning, 4 critical
```

- [ ] **Step 2: Add the readers**

After the `getRAM` section (before `// MARK: - Disk`, line 337), add:

```swift
    // MARK: - Swap & Memory Pressure
    private func getSwap() -> (used: Double, total: Double)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        let gb = 1024.0 * 1024.0 * 1024.0
        return (Double(usage.xsu_used) / gb, Double(usage.xsu_total) / gb)
    }

    private func getMemoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int(level)
    }
```

- [ ] **Step 3: Read and publish in the tick**

In `update(diskToo:)`, next to `let power = self.getPower()`, add:

```swift
            let swap = self.getSwap()
            let pressure = self.getMemoryPressureLevel()
```

Inside `publishOnMain`, after the power updates, add:

```swift
                if let swap = swap {
                    let roundedSwapUsed = (swap.used * 100).rounded() / 100
                    let roundedSwapTotal = (swap.total * 100).rounded() / 100
                    if self.swapUsedGB != roundedSwapUsed { self.swapUsedGB = roundedSwapUsed }
                    if self.swapTotalGB != roundedSwapTotal { self.swapTotalGB = roundedSwapTotal }
                }
                if self.memoryPressureLevel != pressure { self.memoryPressureLevel = pressure }
```

- [ ] **Step 4: Add the optional info row to ProcessListView**

In ProcessListView, after `var onSecondaryAction: ...` (line 445), add:

```swift
    var infoIcon: String? = nil
    var infoText: String? = nil
    var infoDetail: String? = nil
    var infoDetailColor: Color = .white
```

In the body, between the DetailHeader and the "TOP PROCESSES" label (after line 465), add:

```swift
            if infoText != nil || infoDetail != nil {
                HStack(spacing: 6) {
                    if let infoIcon = infoIcon {
                        Image(systemName: infoIcon)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    if let infoText = infoText {
                        Text(infoText)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    if let infoDetail = infoDetail {
                        Circle()
                            .fill(infoDetailColor)
                            .frame(width: 6, height: 6)
                        Text(infoDetail)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.leading, 2)
                .padding(.bottom, 8)
            }
```

- [ ] **Step 5: Wire the RAM call site**

In ContentView's `case .ram:` ProcessListView call, after `onBack: { closeDetail() },` (line 35), add:

```swift
                    infoIcon: "arrow.left.arrow.right",
                    infoText: swapText,
                    infoDetail: pressureLabel,
                    infoDetailColor: pressureColor,
```

And add the helpers next to `formatMB` (around line 407):

```swift
    private var swapText: String? {
        guard monitor.swapTotalGB >= 0 else { return nil }
        if monitor.swapTotalGB == 0 { return "Swap: not in use" }
        return String(format: "Swap: %.1f / %.1f GB", monitor.swapUsedGB, monitor.swapTotalGB)
    }

    private var pressureLabel: String? {
        switch monitor.memoryPressureLevel {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Critical"
        default: return nil
        }
    }

    private var pressureColor: Color {
        switch monitor.memoryPressureLevel {
        case 1: return .green
        case 2: return .orange
        case 4: return .red
        default: return .white
        }
    }
```

- [ ] **Step 6: Build and cross-check**

Run: `cd /Users/karcael/Desktop/MacMonitor && ./build.sh && sysctl vm.swapusage kern.memorystatus_vm_pressure_level`
Expected: clean build; note the terminal values for comparison.

- [ ] **Step 7: Visual check**

Run: `killall MacMonitor 2>/dev/null; sleep 1; open MacMonitor.app --args -debugDetail ram`, wait 8 s, screenshot, Read it.
Expected: swap line matching the sysctl output (or "Swap: not in use" when total is 0) and a green "Normal" pressure dot; process list unaffected. The CPU detail must NOT show the row.

- [ ] **Step 8: Commit**

```bash
git add MacMonitor/SystemMonitor.swift MacMonitor/ContentView.swift
git commit -m "Show swap usage and memory pressure in the Memory detail."
```

---

### Task 6: Disk read/write speed in the Disk detail

**Files:**
- Modify: `MacMonitor/SystemMonitor.swift` (published block, ivars, new Disk I/O section after `getNetworkBytes`/`updateNetworkSpeed` ~line 575, `update(diskToo:)`)
- Modify: `MacMonitor/ContentView.swift` (DiskCleanupView struct lines 1056-1097, call site lines 61-71)

**Interfaces:**
- Consumes: `publishOnMain`.
- Produces: `@Published var diskReadMBs: Double` and `@Published var diskWriteMBs: Double` (default -1, -1 = no sample yet/unavailable, hide row); DiskCleanupView params `readMBs`, `writeMBs`.

- [ ] **Step 1: Add published properties and counters**

After the swap properties (Task 5), add:

```swift
    @Published var diskReadMBs: Double = -1   // -1 = no sample yet, hide row
    @Published var diskWriteMBs: Double = -1
```

Next to `private var lastNetworkTime: Date?` (line 142), add:

```swift
    private var prevDiskRead: UInt64 = 0
    private var prevDiskWrite: UInt64 = 0
    private var lastDiskIOTime: Date?
```

- [ ] **Step 2: Add the Disk I/O section**

After `updateNetworkSpeed()` (line 575, before `// MARK: - Ping`), add:

```swift
    // MARK: - Disk I/O Speed
    private func getDiskIOBytes() -> (read: UInt64, write: UInt64)? {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iter) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var found = false
        while case let drive = IOIteratorNext(iter), drive != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value {
                    totalRead += read
                    found = true
                }
                if let write = (stats["Bytes (Written)"] as? NSNumber)?.uint64Value {
                    totalWrite += write
                    found = true
                }
            }
            IOObjectRelease(drive)
        }
        return found ? (totalRead, totalWrite) : nil
    }

    private func updateDiskIO() {
        let now = Date()
        guard let bytes = getDiskIOBytes() else { return }
        if let last = lastDiskIOTime {
            let elapsed = now.timeIntervalSince(last)
            // Skip the tick when counters went backwards (drive ejected or
            // counters reset); the next tick recovers with fresh baselines.
            if elapsed > 0, bytes.read >= prevDiskRead, bytes.write >= prevDiskWrite {
                let readMBs = Double(bytes.read - prevDiskRead) / elapsed / (1024 * 1024)
                let writeMBs = Double(bytes.write - prevDiskWrite) / elapsed / (1024 * 1024)
                publishOnMain {
                    let r = (readMBs * 10).rounded() / 10
                    let w = (writeMBs * 10).rounded() / 10
                    if self.diskReadMBs != r { self.diskReadMBs = r }
                    if self.diskWriteMBs != w { self.diskWriteMBs = w }
                }
            }
        }
        prevDiskRead = bytes.read
        prevDiskWrite = bytes.write
        lastDiskIOTime = now
    }
```

- [ ] **Step 3: Call it from the tick**

In `update(diskToo:)`'s background block, after `let pressure = self.getMemoryPressureLevel()`, add:

```swift
            self.updateDiskIO()
```

- [ ] **Step 4: Show the row in DiskCleanupView**

Add params after `var onCleanComplete: (() -> Void)? = nil` (line 1065):

```swift
    var readMBs: Double = -1
    var writeMBs: Double = -1
```

In the body, directly after `diskCleanupHeader` (line 1080), add:

```swift
            // Live disk throughput; hidden until the first delta sample
            if readMBs >= 0 || writeMBs >= 0 {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(accent.opacity(0.6))
                        Text(String(format: "R %.1f MB/s", max(readMBs, 0)))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(accent.opacity(0.6))
                        Text(String(format: "W %.1f MB/s", max(writeMBs, 0)))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                }
                .padding(.leading, 2)
                .padding(.bottom, 8)
            }
```

At the ContentView call site (`case .disk:`, after `onCleanComplete: ...` line 70), add:

```swift
                    readMBs: monitor.diskReadMBs,
                    writeMBs: monitor.diskWriteMBs,
```

Note: check the actual parameter order in the DiskCleanupView initializer call and keep the new arguments in declaration order (Swift memberwise init requires it): `readMBs` and `writeMBs` come after `onCleanComplete`.

- [ ] **Step 5: Build and verify with generated I/O**

```bash
cd /Users/karcael/Desktop/MacMonitor && ./build.sh
killall MacMonitor 2>/dev/null; sleep 1; open MacMonitor.app --args -debugDetail disk
sleep 12
dd if=/dev/zero of="$SCRATCH/ddtest" bs=1m count=3000 2>/dev/null &
sleep 6
# screenshot now, while dd is writing
```
Read the screenshot. Expected: R/W row under the Disk Cleanup header with W clearly above 0 while dd runs. Then clean up: `rm -f "$SCRATCH/ddtest"`.

- [ ] **Step 6: Commit**

```bash
git add MacMonitor/SystemMonitor.swift MacMonitor/ContentView.swift
git commit -m "Show live disk read and write speed in the Disk detail."
```

---

### Task 7: Documentation and deploy

**Files:**
- Modify: `architecture.md` (SystemMonitor, ContentView, MacMonitorApp, Components sections)
- Modify: `memory.md` (new dated section at the top, in Turkish)
- Modify: `README.md` (feature list)

**Interfaces:** none; documentation only.

- [ ] **Step 1: Update architecture.md**

Add to the relevant component sections (match the file's existing English style):
- SystemMonitor: SMC power keys (PSTR/PHPC/PDTR with candidate discovery, `powerKeyAvailable` cache), swap via `vm.swapusage`, pressure via `kern.memorystatus_vm_pressure_level`, disk I/O via IOBlockStorageDriver deltas.
- Components: `UILayout.mainHeight(hasBattery:showPower:showNetwork:showIP:)` and the row height constants; `HistoryStore.power`.
- ContentView: power row, row visibility via `widgetRow_*` @AppStorage flags, ProcessListView info row, DiskCleanupView throughput row, ThermalsView power section.
- MacMonitorApp: Power stats line, Widget Rows submenu, registered defaults.

- [ ] **Step 2: Update memory.md**

Add a new Turkish section at the top titled "Sürüm 2.1 (Temmuz 2026): Güç metrikleri ve satır gizleme" summarizing: SMC güç anahtarları (PSTR/PHPC/PDTR, M4'te probe ile doğrulandı), widget güç satırı, menü Power satırı, Widget Rows alt menüsü (`widgetRow_*` UserDefaults), dinamik yükseklik artık görünür satır sayısından hesaplanıyor, Thermals güç bölümü ve grafiği, RAM detayında swap ve bellek basıncı, Disk detayında anlık okuma/yazma hızı, veri yoksa satır gizleme kuralı.

- [ ] **Step 3: Update README.md feature list**

Add bullets for: live power consumption (widget, menu and Thermals breakdown), swap and memory pressure, disk read/write speed, and the Widget Rows show/hide menu.

- [ ] **Step 4: Deploy to /Applications (existing copy there)**

```bash
killall MacMonitor 2>/dev/null
cp -r /Users/karcael/Desktop/MacMonitor/MacMonitor.app /Applications/
open /Applications/MacMonitor.app
```
Expected: widget appears with the power row; final visual smoke check via screenshot.

- [ ] **Step 5: Commit**

```bash
git add architecture.md memory.md README.md
git commit -m "Document power metrics, extra stats and widget row toggles."
```
