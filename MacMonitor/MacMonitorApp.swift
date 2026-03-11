import SwiftUI
import AppKit

@main
struct MacMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()

        let size = NSSize(width: 300, height: 300)

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

        // SwiftUI content
        let hosting = NSHostingView(rootView: ContentView())
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

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: "MacMonitor")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Widget", action: #selector(showWidget), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func showWidget() {
        window.orderFrontRegardless()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
