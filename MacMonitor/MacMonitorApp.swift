import SwiftUI
import AppKit
import ServiceManagement
import IOKit.pwr_mgt

@main
struct MacMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem?
    let monitor = SystemMonitor()

    // Menu items for live stats
    private var cpuMenuItem: NSMenuItem!
    private var ramMenuItem: NSMenuItem!
    private var diskMenuItem: NSMenuItem!
    private var tempMenuItem: NSMenuItem!
    private var fanMenuItem: NSMenuItem!
    private var gpuMenuItem: NSMenuItem!
    private var uptimeMenuItem: NSMenuItem!
    private var loadMenuItem: NSMenuItem!
    private var powerMenuItem: NSMenuItem!
    private var widgetRowPowerItem: NSMenuItem!
    private var widgetRowNetworkItem: NSMenuItem!
    private var widgetRowIPItem: NSMenuItem!
    private var menuUpdateTimer: Timer?
    private var launchAtLoginItem: NSMenuItem!
    private var alertsMenuItem: NSMenuItem!
    private var keepAwakeItem: NSMenuItem!
    private var menuBarTextItem: NSMenuItem!
    private var lockPositionItem: NSMenuItem!
    private var statusTextTimer: Timer?
    private var awakeAssertionID: IOPMAssertionID = 0

    // Window geometry bookkeeping for dynamic height
    private var savedGridFrame: NSRect?
    private var userMovedDuringDetail = false
    private var isProgrammaticResize = false

    // Drag tracking: a mouse-down on the widget marks a possible user drag;
    // the move is snapped to the widget grid and persisted once the button is
    // released. Moves made by macOS itself (display changes) are never saved.
    private var userDragActive = false
    private var mouseDownCount = 0
    private var dragEndTimer: Timer?
    private var mouseMonitor: Any?

    private enum PositionKey {
        static let x = "windowX"
        static let y = "windowY"
        static let onGrid = "windowOnGrid"   // saved origin is a grid slot
        static let locked = "windowLocked"
    }

    private var menuBarTextEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "menuBarText") }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarText") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "widgetRow_power": true,
            "widgetRow_network": true,
            "widgetRow_ip": true
        ])

        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()

        let size = NSSize(width: UILayout.width, height: UILayout.mainHeight)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // NSVisualEffectView — native macOS widget material
        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.appearance = NSAppearance(named: .darkAqua)

        // Native continuous corners via maskImage (no border artifacts)
        visualEffect.maskImage = WidgetChrome.cornerMask()

        // SwiftUI content — share the same monitor instance
        let hosting = NSHostingView(rootView: ContentView(monitor: monitor))
        // AppDelegate owns the window size (fixed widget grid sizes); without
        // this the SwiftUI content's ideal size silently overrides it.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        visualEffect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        window.contentView = visualEffect
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // Desktop level, one step above native desktop widgets (they sit at
        // desktop icon level + 2), so a widget dropped onto MacMonitor's slot
        // never covers it. Desktop icons stay below, app windows above.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = !UserDefaults.standard.bool(forKey: PositionKey.locked)
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        placeWindowAtLaunch()
        observeWindowPlacement()

        // Resize requests from SwiftUI when switching between grid and detail
        NotificationCenter.default.addObserver(
            forName: .mmResizeWindow,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let height = note.userInfo?["height"] as? CGFloat else { return }
            let isDetail = note.userInfo?["isDetail"] as? Bool ?? false
            self?.resizeWindow(to: height, isDetail: isDetail)
        }

        window.orderFrontRegardless()
    }

    /// Grows or shrinks a frame to the given height, keeping whichever
    /// vertical edge sits closer to a screen edge fixed, then clamps the
    /// result into the visible area.
    private func anchoredFrame(from old: NSRect, height: CGFloat) -> NSRect {
        var frame = old
        frame.size.height = height
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let topGap = visible.maxY - old.maxY
            let bottomGap = old.minY - visible.minY
            if topGap < bottomGap {
                // Window hugs the top of the screen: keep the top edge fixed
                frame.origin.y = old.maxY - height
            }
            if frame.maxY > visible.maxY { frame.origin.y -= frame.maxY - visible.maxY }
            if frame.origin.y < visible.minY { frame.origin.y = visible.minY }
        }
        return frame
    }

    /// Animates the window to a new height. Entering a detail view saves the
    /// grid frame; returning restores it exactly, so the widget never drifts
    /// away from its slot. If the user moved the window while a detail view
    /// was open, it lands on the nearest grid slot instead.
    private func resizeWindow(to height: CGFloat, isDetail: Bool) {
        let current = window.frame
        guard current.height != height else { return }

        let target: NSRect
        if isDetail {
            savedGridFrame = current
            target = anchoredFrame(from: current, height: height)
        } else {
            // Only a real drag counts; a move macOS made during the detail
            // (display change) falls back to the saved grid frame.
            if let saved = savedGridFrame, !userMovedDuringDetail {
                target = anchoredFrame(from: saved, height: height)
            } else {
                target = snappedFrame(for: anchoredFrame(from: current, height: height))
                persistPosition(target.origin)
            }
            savedGridFrame = nil
            userMovedDuringDetail = false
        }

        animateWindow(to: target, duration: 0.28)
    }

    private func animateWindow(to target: NSRect, duration: TimeInterval) {
        isProgrammaticResize = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.window.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.isProgrammaticResize = false
        })
    }

    /// Moves the window without animation and without treating it as a user move.
    private func setWindowFrame(_ frame: NSRect) {
        isProgrammaticResize = true
        window.setFrame(frame, display: true)
        isProgrammaticResize = false
    }

    // MARK: - Window Placement

    /// Restores the saved grid slot. The first launch and positions saved
    /// before grid snapping existed are snapped once and persisted, so the
    /// widget never re-flows on later launches.
    private func placeWindowAtLaunch() {
        let d = UserDefaults.standard
        guard let x = d.object(forKey: PositionKey.x) as? CGFloat,
              let y = d.object(forKey: PositionKey.y) as? CGFloat else {
            let slot = defaultSlot()
            setWindowFrame(slot)
            persistPosition(slot.origin)
            return
        }

        let saved = NSRect(origin: NSPoint(x: x, y: y), size: window.frame.size)
        if screen(containing: saved) == nil {
            // The saved display is not connected: show the widget on the main
            // screen but keep the saved slot for when the display returns.
            setWindowFrame(defaultSlot())
        } else if d.bool(forKey: PositionKey.onGrid) {
            setWindowFrame(saved)
        } else {
            let slot = snappedFrame(for: saved)
            setWindowFrame(slot)
            persistPosition(slot.origin)
        }
    }

    private func observeWindowPlacement() {
        // A mouse-down on the widget marks a possible drag. Local monitors see
        // only this app's own events, so there is no cost otherwise.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            if event.type == .leftMouseDown {
                self.mouseDownCount += 1
                self.userDragActive = true
            } else if self.dragEndTimer == nil {
                // No move seen yet: allow a moment for a late move
                // notification, then treat the press as a plain click.
                let press = self.mouseDownCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self, self.mouseDownCount == press, self.dragEndTimer == nil else { return }
                    self.userDragActive = false
                }
            }
            return event
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isProgrammaticResize, self.userDragActive else { return }
            self.waitForDragEnd()
        }

        // Displays sleeping, waking or being rearranged can make macOS move
        // the window; put it back on its saved slot.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restoreSavedSlot()
        }
    }

    /// Polls the mouse button only while a drag is in progress, then snaps.
    private func waitForDragEnd() {
        guard dragEndTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self.dragEndTimer = nil
            self.userDragActive = false
            self.finishUserDrag()
        }
        RunLoop.main.add(timer, forMode: .common)
        dragEndTimer = timer
    }

    private func finishUserDrag() {
        // A detail view is taller than the grid slot; it snaps when it
        // returns to the grid size (see resizeWindow).
        guard savedGridFrame == nil else {
            userMovedDuringDetail = true
            return
        }
        let slot = snappedFrame(for: window.frame)
        persistPosition(slot.origin)
        animateWindow(to: slot, duration: 0.18)
    }

    /// Puts the widget back on its saved slot after display changes. Nothing
    /// is persisted here: only user drags change the saved position.
    private func restoreSavedSlot() {
        guard savedGridFrame == nil, dragEndTimer == nil,
              let x = UserDefaults.standard.object(forKey: PositionKey.x) as? CGFloat,
              let y = UserDefaults.standard.object(forKey: PositionKey.y) as? CGFloat else { return }
        let saved = NSRect(origin: NSPoint(x: x, y: y), size: window.frame.size)
        if screen(containing: saved) != nil {
            if saved.origin != window.frame.origin { setWindowFrame(saved) }
        } else if screen(containing: window.frame) == nil {
            setWindowFrame(defaultSlot())
        }
    }

    private func persistPosition(_ origin: NSPoint) {
        let d = UserDefaults.standard
        d.set(origin.x, forKey: PositionKey.x)
        d.set(origin.y, forKey: PositionKey.y)
        d.set(true, forKey: PositionKey.onGrid)
    }

    /// Bottom-right slot of the main screen: first launch, or the saved
    /// display is not connected.
    private func defaultSlot() -> NSRect {
        guard let visible = NSScreen.main?.visibleFrame else { return window.frame }
        let size = NSSize(width: UILayout.width, height: UILayout.mainHeight)
        let corner = NSRect(
            x: visible.maxX - size.width - WindowSnapper.gutter,
            y: visible.minY + WindowSnapper.gutter,
            width: size.width, height: size.height
        )
        return snappedFrame(for: corner)
    }

    /// Snaps a frame onto the widget grid of the screen it is mostly on.
    private func snappedFrame(for frame: NSRect) -> NSRect {
        guard let screen = screen(containing: frame) ?? NSScreen.main else { return frame }
        return WindowSnapper.snappedFrame(
            for: frame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            menuBarHeight: menuBarHeight(),
            widgetWindows: nativeWidgetWindows()
        )
    }

    /// The screen sharing the largest area with the frame, nil when off screen.
    private func screen(containing frame: NSRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen
    }

    /// Menu bar height, read from the primary display: with one shared menu
    /// bar, other displays report a full-height visible frame.
    private func menuBarHeight() -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 0 }
        return primary.frame.maxY - primary.visibleFrame.maxY
    }

    /// Frames of native desktop widget windows in Cocoa coordinates. Window
    /// bounds and owners are readable without Screen Recording permission.
    private func nativeWidgetWindows() -> [CGRect] {
        let hostPIDs = Set(NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .map(\.processIdentifier))
        guard !hostPIDs.isEmpty,
              let primaryHeight = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, hostPIDs.contains(pid),
                  let layer = entry[kCGWindowLayer as String] as? Int, layer < normalLevel,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 100, bounds.height >= 100
            else { return nil }
            return WindowSnapper.cocoaRect(fromCG: bounds, primaryScreenHeight: primaryHeight)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: "MacMonitor")
        }

        let menu = NSMenu()
        menu.delegate = self

        // Stats header
        let headerItem = NSMenuItem(title: "MacMonitor", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        let headerAttr = NSAttributedString(string: "MacMonitor", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        headerItem.attributedTitle = headerAttr
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        cpuMenuItem = makeStatsItem("cpu", "CPU", "—")
        ramMenuItem = makeStatsItem("memorychip", "Memory", "—")
        diskMenuItem = makeStatsItem("internaldrive", "Disk", "—")
        tempMenuItem = makeStatsItem("thermometer.medium", "Temp", "—")
        fanMenuItem = makeStatsItem("fan.fill", "Fan", "—")
        powerMenuItem = makeStatsItem("bolt.fill", "Power", "—")
        gpuMenuItem = makeStatsItem("display", "GPU", "—")
        uptimeMenuItem = makeStatsItem("clock", "Uptime", "—")
        loadMenuItem = makeStatsItem("chart.bar", "Load", "—")

        menu.addItem(cpuMenuItem)
        menu.addItem(ramMenuItem)
        menu.addItem(diskMenuItem)
        menu.addItem(tempMenuItem)
        menu.addItem(fanMenuItem)
        menu.addItem(powerMenuItem)
        menu.addItem(gpuMenuItem)
        menu.addItem(uptimeMenuItem)
        menu.addItem(loadMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Theme submenu
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Theme")
        themeItem.image?.size = NSSize(width: 14, height: 14)
        let themeMenu = NSMenu()
        for theme in AppTheme.allCases {
            let item = NSMenuItem(title: theme.rawValue, action: #selector(themeSelected(_:)), keyEquivalent: "")
            item.representedObject = theme.rawValue
            item.target = self
            if theme == monitor.theme { item.state = .on }
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

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

        // Lock Position: turns off dragging so the widget cannot be moved by accident
        lockPositionItem = NSMenuItem(title: "Lock Position", action: #selector(toggleLockPosition), keyEquivalent: "")
        lockPositionItem.target = self
        lockPositionItem.state = UserDefaults.standard.bool(forKey: PositionKey.locked) ? .on : .off
        menu.addItem(lockPositionItem)

        menu.addItem(NSMenuItem.separator())

        // Threshold notifications (high temp, disk almost full)
        alertsMenuItem = NSMenuItem(title: "Alerts", action: #selector(toggleAlerts), keyEquivalent: "")
        alertsMenuItem.target = self
        alertsMenuItem.state = monitor.alertsEnabled ? .on : .off
        menu.addItem(alertsMenuItem)

        // Keep Awake: prevents display and idle sleep while enabled
        keepAwakeItem = NSMenuItem(title: "Keep Mac Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwakeItem.target = self
        menu.addItem(keepAwakeItem)

        // Compact live stats as menu bar text instead of the gauge icon
        menuBarTextItem = NSMenuItem(title: "Stats in Menu Bar", action: #selector(toggleMenuBarText), keyEquivalent: "")
        menuBarTextItem.target = self
        menuBarTextItem.state = menuBarTextEnabled ? .on : .off
        menu.addItem(menuBarTextItem)

        // Launch at Login
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Widget", action: #selector(showWidget), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide Widget", action: #selector(hideWidget), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu

        // Restore persisted menu bar text mode
        applyStatusItemMode()
    }

    private func makeStatsItem(_ symbolName: String, _ label: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label):  \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.image?.size = NSSize(width: 14, height: 14)
        return item
    }

    private func makeWidgetRowItem(_ title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleWidgetRow(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        return item
    }

    private func updateMenuStats() {
        let cpu = String(format: "%.0f%%", monitor.cpuUsage)
        let ram = String(format: "%.1f / %.0f GB", monitor.usedRAM, monitor.totalRAM)
        let disk = monitor.diskLabel
        let temp = monitor.cpuTemp > 0 ? String(format: "%.0f°C", monitor.cpuTemp) : "--"

        cpuMenuItem.title = "CPU:  \(cpu)"
        ramMenuItem.title = "Memory:  \(ram)"
        diskMenuItem.title = "Disk:  \(disk)"
        tempMenuItem.title = "Temp:  \(temp)"

        if monitor.fans.isEmpty {
            fanMenuItem.isHidden = true
        } else {
            fanMenuItem.isHidden = false
            let fanText: String
            if monitor.fans.count == 1 {
                fanText = String(format: "%.0f RPM", monitor.fans[0].actualRPM)
            } else {
                fanText = monitor.fans.map { String(format: "%.0f", $0.actualRPM) }.joined(separator: " / ") + " RPM"
            }
            fanMenuItem.title = "Fan:  \(fanText)"
        }

        if monitor.systemPowerW > 0 {
            powerMenuItem.isHidden = false
            powerMenuItem.title = String(format: "Power:  %.1f W", monitor.systemPowerW)
        } else {
            powerMenuItem.isHidden = true
        }
        // No power data means the toggle would be a no-op; hide it too
        widgetRowPowerItem.isHidden = monitor.systemPowerW <= 0

        if let gpu = monitor.readGPUUsage() {
            gpuMenuItem.isHidden = false
            gpuMenuItem.title = String(format: "GPU:  %.0f%%", gpu)
        } else {
            gpuMenuItem.isHidden = true
        }

        uptimeMenuItem.title = "Uptime:  \(monitor.uptimeText())"
        loadMenuItem.title = "Load:  \(monitor.loadText())"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuStats()
        // Menu tracking runs the main loop in event-tracking mode; the timer
        // must live in common modes or it never fires while the menu is open.
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateMenuStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        menuUpdateTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuUpdateTimer?.invalidate()
        menuUpdateTimer = nil
    }

    // MARK: - Actions

    @objc private func toggleAlerts() {
        monitor.alertsEnabled.toggle()
        alertsMenuItem.state = monitor.alertsEnabled ? .on : .off
    }

    @objc private func toggleLockPosition() {
        let locked = !UserDefaults.standard.bool(forKey: PositionKey.locked)
        UserDefaults.standard.set(locked, forKey: PositionKey.locked)
        window.isMovableByWindowBackground = !locked
        lockPositionItem.state = locked ? .on : .off
    }

    @objc private func toggleWidgetRow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let newValue = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newValue, forKey: key)
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleKeepAwake() {
        if awakeAssertionID != 0 {
            IOPMAssertionRelease(awakeAssertionID)
            awakeAssertionID = 0
            keepAwakeItem.state = .off
        } else {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MacMonitor Keep Awake" as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                awakeAssertionID = assertionID
                keepAwakeItem.state = .on
            } else {
                showAlert("Could not enable Keep Awake.")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if awakeAssertionID != 0 { IOPMAssertionRelease(awakeAssertionID) }
    }

    // MARK: - Menu Bar Text Mode

    @objc private func toggleMenuBarText() {
        menuBarTextEnabled.toggle()
        menuBarTextItem.state = menuBarTextEnabled ? .on : .off
        applyStatusItemMode()
    }

    private func applyStatusItemMode() {
        guard let button = statusItem?.button else { return }
        statusTextTimer?.invalidate()
        statusTextTimer = nil

        if menuBarTextEnabled {
            statusItem?.length = NSStatusItem.variableLength
            button.image = nil
            updateStatusText()
            let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.updateStatusText()
            }
            RunLoop.main.add(timer, forMode: .common)
            statusTextTimer = timer
        } else {
            statusItem?.length = NSStatusItem.squareLength
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: "MacMonitor")
        }
    }

    private func updateStatusText() {
        guard let button = statusItem?.button else { return }
        var parts = [String(format: "%.0f%%", monitor.cpuUsage)]
        if monitor.cpuTemp > 0 { parts.append(String(format: "%.0f°", monitor.cpuTemp)) }
        button.attributedTitle = NSAttributedString(string: parts.joined(separator: " "), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ])
    }

    @objc private func themeSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let theme = AppTheme(rawValue: rawValue) else { return }
        monitor.theme = theme
        // Update checkmarks
        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = (item.representedObject as? String) == rawValue ? .on : .off
            }
        }
    }

    // MARK: - Launch at Login

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        // Ensure app is in /Applications first
        let appPath = Bundle.main.bundlePath
        let appsPath = "/Applications/MacMonitor.app"

        if appPath != appsPath {
            do {
                if FileManager.default.fileExists(atPath: appsPath) {
                    try FileManager.default.removeItem(atPath: appsPath)
                }
                try FileManager.default.copyItem(atPath: appPath, toPath: appsPath)
            } catch {
                showAlert("Could not copy to Applications folder.\nTry moving MacMonitor.app to /Applications manually.")
                return
            }
        }

        if #available(macOS 13.0, *) {
            do {
                if isLaunchAtLoginEnabled() {
                    try SMAppService.mainApp.unregister()
                    launchAtLoginItem.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    launchAtLoginItem.state = .on
                }
            } catch {
                showAlert("Could not update Login Items.\nYou can add it manually in System Settings → General → Login Items.")
            }
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacMonitor"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showWidget() {
        window.orderFrontRegardless()
    }

    @objc private func hideWidget() {
        window.orderOut(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
