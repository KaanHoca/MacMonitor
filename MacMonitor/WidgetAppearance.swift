import AppKit

/// Light or dark rendering, chosen in the Appearance menu.
enum AppearanceMode: String, CaseIterable {
    case auto, light, dark

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Full-color or glass rendering, chosen in the Widget Style menu. Mirrors
/// the macOS "Widget style" setting.
enum WidgetStyleMode: String, CaseIterable {
    case auto, fullColor, glass

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .fullColor: return "Full-color"
        case .glass: return "Glass"
        }
    }
}

/// Resolves how the widget renders and persists the two menu choices.
/// `onChange` fires after every resolution so the window can update its
/// appearance and background.
final class WidgetAppearance: ObservableObject {
    private enum Key {
        static let appearance = "appearanceMode"
        static let style = "widgetStyle"
    }

    @Published var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Key.appearance)
            resolve()
        }
    }

    @Published var styleMode: WidgetStyleMode {
        didSet {
            UserDefaults.standard.set(styleMode.rawValue, forKey: Key.style)
            if styleMode == .auto { refreshFromVisibleWindows() }
            resolve()
        }
    }

    /// True while the widget renders as glass.
    @Published private(set) var isGlass = false

    var onChange: (() -> Void)?

    /// Last detected state of the native widgets, used by Automatic style.
    var nativeDimmed = false

    init() {
        let defaults = UserDefaults.standard
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .auto
        styleMode = WidgetStyleMode(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .auto
        resolve()
    }

    /// Window appearance: nil follows the system. It also tints the glass,
    /// which is light in Light like dimmed native widgets; the glass content
    /// itself is forced dark by WidgetBackgroundView.
    var windowAppearance: NSAppearance? {
        switch appearanceMode {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func resolve() {
        let glass: Bool
        switch styleMode {
        case .fullColor: glass = false
        case .glass: glass = true
        case .auto: glass = nativeDimmed
        }
        if glass != isGlass { isGlass = glass }
        onChange?()
    }

    // MARK: - Automatic Tracking

    private weak var trackedWindow: NSWindow?
    private var clickMonitor: Any?
    private var recheckTimer: Timer?

    /// Follows the native widgets' state for Automatic style using global
    /// clicks, app activations and display changes only; no polling. Global
    /// monitors never see clicks on MacMonitor itself, which matches native
    /// widgets ignoring them.
    func startTracking(window: NSWindow) {
        trackedWindow = window
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.handleClick(at: NSEvent.mouseLocation)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRecheck()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshFromVisibleWindows()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.refreshFromVisibleWindows()
        }
        refreshFromVisibleWindows()
    }

    private func handleClick(at cocoaPoint: NSPoint) {
        guard styleMode == .auto, let display = trackedDisplay() else { return }
        switch DesktopFocusRule.classifyClick(at: cgPoint(cocoaPoint), display: display, windows: windowSnapshot()) {
        case .fullColor: setNativeDimmed(false)
        case .dimmed: setNativeDimmed(true)
        case .recheck: scheduleRecheck()
        case .unchanged: break
        }
    }

    /// Windows slide back or away after the event, so look again shortly after.
    private func scheduleRecheck() {
        guard styleMode == .auto else { return }
        recheckTimer?.invalidate()
        let timer = Timer(timeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self = self, let display = self.trackedDisplay() else { return }
            if DesktopFocusRule.appWindowVisible(on: display, windows: self.windowSnapshot()) {
                self.setNativeDimmed(true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    /// Launch, display changes and moving to another display: dimmed when
    /// an app window is visible on the widget's display.
    func refreshFromVisibleWindows() {
        guard styleMode == .auto, let display = trackedDisplay() else { return }
        setNativeDimmed(DesktopFocusRule.appWindowVisible(on: display, windows: windowSnapshot()))
    }

    private func setNativeDimmed(_ dimmed: Bool) {
        guard dimmed != nativeDimmed else { return }
        nativeDimmed = dimmed
        resolve()
    }

    /// The widget's display in CG coordinates.
    private func trackedDisplay() -> CGRect? {
        guard let frame = trackedWindow?.screen?.frame,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private func cgPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    /// Front-to-back on-screen windows with owners resolved by bundle id.
    private func windowSnapshot() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var owners: [pid_t: WindowOwner] = [:]
        for app in NSWorkspace.shared.runningApplications {
            switch app.bundleIdentifier {
            case "com.apple.finder": owners[app.processIdentifier] = .finder
            case "com.apple.dock": owners[app.processIdentifier] = .dock
            case "com.apple.notificationcenterui": owners[app.processIdentifier] = .widgetHost
            default: break
            }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            let owner: WindowOwner
            if pid == ownPID {
                owner = .macMonitor
            } else if let known = owners[pid] {
                owner = known
            } else if (entry[kCGWindowOwnerName as String] as? String) == "Window Server" {
                owner = .windowServer
            } else {
                owner = .other
            }
            return WindowInfo(owner: owner, layer: layer, bounds: bounds,
                              alpha: entry[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}
