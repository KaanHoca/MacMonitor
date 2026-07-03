import SwiftUI
import AppKit
import ServiceManagement

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
    private var menuUpdateTimer: Timer?
    private var launchAtLoginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()

        let size = NSSize(width: 300, height: 320)

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

        // Rounded corners via maskImage — no border artifacts
        visualEffect.maskImage = roundedMask(cornerRadius: 18)

        // SwiftUI content — share the same monitor instance
        let hosting = NSHostingView(rootView: ContentView(monitor: monitor))
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

        // Desktop level — app windows float above this
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        // Restore saved position or default to bottom-right
        if let savedX = UserDefaults.standard.object(forKey: "windowX") as? CGFloat,
           let savedY = UserDefaults.standard.object(forKey: "windowY") as? CGFloat {
            window.setFrameOrigin(NSPoint(x: savedX, y: savedY))
        } else if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - size.width - 16
            let y = screen.visibleFrame.minY + 16
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Save position whenever the window moves
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let origin = self?.window.frame.origin else { return }
            UserDefaults.standard.set(origin.x, forKey: "windowX")
            UserDefaults.standard.set(origin.y, forKey: "windowY")
        }

        window.orderFrontRegardless()
    }

    /// Creates a stretchable mask image for NSVisualEffectView — clean rounded corners
    private func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let edge = 2.0 * cornerRadius + 1.0
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius,
            bottom: cornerRadius, right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
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

        menu.addItem(cpuMenuItem)
        menu.addItem(ramMenuItem)
        menu.addItem(diskMenuItem)
        menu.addItem(tempMenuItem)
        menu.addItem(fanMenuItem)

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

        menu.addItem(NSMenuItem.separator())

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
    }

    private func makeStatsItem(_ symbolName: String, _ label: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label):  \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.image?.size = NSSize(width: 14, height: 14)
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

        let fanText: String
        if monitor.fans.isEmpty {
            fanText = "No fans"
        } else if monitor.fans.count == 1 {
            fanText = String(format: "%.0f RPM", monitor.fans[0].actualRPM)
        } else {
            fanText = monitor.fans.map { String(format: "%.0f", $0.actualRPM) }.joined(separator: " / ") + " RPM"
        }
        fanMenuItem.title = "Fan:  \(fanText)"
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
