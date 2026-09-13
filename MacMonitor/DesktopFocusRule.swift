import CoreGraphics

/// Who owns a window, resolved by bundle id (window owner names are localized).
enum WindowOwner: Equatable {
    case finder, dock, windowServer, widgetHost, macMonitor, other
}

/// The parts of a CGWindowList entry the rule needs. Bounds are in CG
/// coordinates (origin at the top-left of the primary display).
struct WindowInfo: Equatable {
    let owner: WindowOwner
    let layer: Int
    let bounds: CGRect
    let alpha: Double
}

enum WidgetStateChange: Equatable {
    case fullColor, dimmed, unchanged, recheck
}

/// Mirrors when native macOS desktop widgets switch between full-color and
/// the dimmed glass state. Measured on macOS 26: the state follows the
/// per-display "desktop revealed" state, not the frontmost app. Clicking the
/// wallpaper reveals it (full-color); clicking an app window or bringing
/// windows back dims; clicking widgets or other displays changes nothing.
/// Pure logic over a front-to-back window list; no AppKit state.
enum DesktopFocusRule {
    static let desktopIconLevel = -2147483603   // CGWindowLevelForKey(.desktopIconWindow)
    static let dockLevel = 20                   // Dock and its overlays
    static let revealLevel = 18                 // Dock windows seen while the desktop is revealed
    static let appWindowLevels = 0..<18         // normal, floating and panel windows

    /// Classifies a left mouse-down at `point` for the widget's `display`.
    static func classifyClick(at point: CGPoint, display: CGRect, windows: [WindowInfo]) -> WidgetStateChange {
        guard display.contains(point),
              let hit = windows.first(where: { isHit($0, at: point, display: display) })
        else { return .unchanged }

        switch hit.owner {
        case .macMonitor, .widgetHost:
            return .unchanged
        case .finder where hit.layer == desktopIconLevel:
            return .fullColor
        case .dock where hit.layer < 0:
            return .fullColor
        case .windowServer where hit.layer < 0:
            return .fullColor
        case .dock where hit.layer == revealLevel:
            return .recheck
        default:
            return appWindowLevels.contains(hit.layer) ? .dimmed : .unchanged
        }
    }

    /// True when an app window covers a meaningful part of `display`. Parked
    /// windows leave only a thin sliver on screen and do not count.
    static func appWindowVisible(on display: CGRect, windows: [WindowInfo]) -> Bool {
        windows.contains { window in
            guard window.alpha > 0, appWindowLevels.contains(window.layer),
                  window.owner != .macMonitor, window.owner != .widgetHost else { return false }
            let overlap = window.bounds.intersection(display)
            return !overlap.isNull && overlap.width >= 100 && overlap.height >= 100
        }
    }

    /// Full-display Dock overlays sit above everything at Dock level but let
    /// clicks through, so they never count as the clicked window.
    private static func isHit(_ window: WindowInfo, at point: CGPoint, display: CGRect) -> Bool {
        guard window.alpha > 0, window.bounds.contains(point) else { return false }
        let coversDisplay = window.bounds.width >= display.width && window.bounds.height >= display.height
        return !(window.owner == .dock && window.layer >= dockLevel && coversDisplay)
    }
}
