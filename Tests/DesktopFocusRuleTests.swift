import CoreGraphics
import Foundation

// DesktopFocusRule tests. Fixtures are the windows under real clicks logged
// while sampling a native widget on macOS 26.6; expected values are the
// native widget states observed at those clicks. Run with ./test.sh.

@main
struct DesktopFocusRuleTests {
    static var failures = 0

    static func expect<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name): got \(got), want \(want)")
        }
    }

    static let right = CGRect(x: 2560, y: 0, width: 2560, height: 1440)     // widget display

    static let finderDesktop = WindowInfo(owner: .finder, layer: -2147483603, bounds: right, alpha: 1)
    static let dockDesktop = WindowInfo(owner: .dock, layer: -2147483624, bounds: right, alpha: 1)
    static let wallpaper = WindowInfo(owner: .windowServer, layer: -2147483626, bounds: right, alpha: 1)
    static let terminal = WindowInfo(owner: .other, layer: 0, bounds: CGRect(x: 2711, y: 240, width: 1192, height: 1013), alpha: 1)
    static let macMonitor = WindowInfo(owner: .macMonitor, layer: -2147483600, bounds: CGRect(x: 3680, y: 46, width: 344, height: 344), alpha: 1)
    static let reminders = WindowInfo(owner: .widgetHost, layer: -2147483601, bounds: CGRect(x: 4032, y: 38, width: 360, height: 360), alpha: 1)
    static let dockOverlay = WindowInfo(owner: .dock, layer: 20, bounds: right, alpha: 1)
    static let dockBar = WindowInfo(owner: .dock, layer: 20, bounds: CGRect(x: 3200, y: 1384, width: 1160, height: 56), alpha: 1)
    static let dockReveal = WindowInfo(owner: .dock, layer: 18, bounds: CGRect(x: 3300, y: 300, width: 500, height: 400), alpha: 1)
    static let background = [finderDesktop, dockDesktop, wallpaper]

    static func main() {
        expect("Clicking the wallpaper reveals the desktop",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 3129, y: 821), display: right, windows: background),
               .fullColor)
        expect("Clicking MacMonitor changes nothing",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 3695, y: 363), display: right, windows: [macMonitor] + background),
               .unchanged)
        expect("Clicking a native widget changes nothing",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 4200, y: 200), display: right, windows: [reminders] + background),
               .unchanged)
        expect("Clicking an app window on the widget display dims",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 3043, y: 939), display: right, windows: [terminal] + background),
               .dimmed)
        expect("Clicks on another display change nothing",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 1824, y: 860), display: right,
                                              windows: [WindowInfo(owner: .other, layer: 0, bounds: CGRect(x: 1000, y: 400, width: 1400, height: 900), alpha: 1)]),
               .unchanged)
        expect("The full-display Dock overlay lets the click through",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 3000, y: 500), display: right, windows: [dockOverlay, terminal] + background),
               .dimmed)
        expect("Clicking the Dock bar is not a wallpaper click",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 3500, y: 1400), display: right, windows: [dockBar] + background),
               .unchanged)
        expect("A Dock layer 18 window asks for a recheck",
               DesktopFocusRule.classifyClick(at: CGPoint(x: 3408, y: 536), display: right, windows: [dockReveal] + background),
               .recheck)

        expect("An app window on the display is visible",
               DesktopFocusRule.appWindowVisible(on: right, windows: [terminal] + background), true)
        expect("Widgets and the desktop are not app windows",
               DesktopFocusRule.appWindowVisible(on: right, windows: [macMonitor, reminders] + background), false)
        expect("A parked window sliver does not count",
               DesktopFocusRule.appWindowVisible(on: right, windows: [WindowInfo(owner: .other, layer: 0, bounds: CGRect(x: 5080, y: 300, width: 1000, height: 800), alpha: 1)] + background), false)
        expect("A window on another display does not count",
               DesktopFocusRule.appWindowVisible(on: right, windows: [WindowInfo(owner: .other, layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600), alpha: 1)]), false)

        expect("A visible app window on a refresh dims",
               DesktopFocusRule.refresh(appWindowVisible: true), .dimmed)
        expect("An empty display on a refresh keeps the current state",
               DesktopFocusRule.refresh(appWindowVisible: false), .unchanged)

        print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
