import CoreGraphics
import Foundation

// Geometry tests for WindowSnapper. Run with ./test.sh (plain swiftc, no
// XCTest). Fixtures are real measurements from a Mac mini M4 on macOS 26.6
// with three 2560x1440 displays; expected values are derived by hand.

@main
struct WindowSnapperTests {
    static var failures = 0

    static func expect(_ name: String, _ got: CGPoint, _ want: CGPoint) {
        if abs(got.x - want.x) < 0.5 && abs(got.y - want.y) < 0.5 {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name): got (\(got.x), \(got.y)), want (\(want.x), \(want.y))")
        }
    }

    // Primary display: menu bar on top (30pt), Dock at the bottom (56pt).
    static let primaryFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let primaryVisible = CGRect(x: 0, y: 56, width: 2560, height: 1354)

    // Right display: no menu bar or Dock, so the visible frame is the full frame.
    static let rightFrame = CGRect(x: 2560, y: 0, width: 2560, height: 1440)

    static let menuBarHeight: CGFloat = 30

    // Native widget windows on the right display, converted from their
    // CGWindowList bounds to Cocoa coordinates (y = 1440 - cgY - height).
    static let rightWidgets: [CGRect] = [
        CGRect(x: 4032, y: 1042, width: 360, height: 360),
        CGRect(x: 4032, y: 682, width: 360, height: 360),
        CGRect(x: 4392, y: 862, width: 360, height: 360),
        CGRect(x: 4392, y: 682, width: 360, height: 180),
        CGRect(x: 4392, y: 1222, width: 360, height: 180),
        CGRect(x: 4752, y: 1042, width: 360, height: 360),
        CGRect(x: 4752, y: 862, width: 360, height: 180),
        CGRect(x: 4752, y: 682, width: 360, height: 180),
    ]

    static func frame(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 344, height: 344)
    }

    static func main() {
        let converted = WindowSnapper.cocoaRect(
            fromCG: CGRect(x: 4032, y: 38, width: 360, height: 360),
            primaryScreenHeight: 1440
        )
        expect("CGWindowList bounds convert to Cocoa coordinates",
               converted.origin, CGPoint(x: 4032, y: 1042))

        expect("A small accidental drag returns to the same slot",
               WindowSnapper.snappedFrame(
                   for: frame(3677, 1045),
                   screenFrame: rightFrame, visibleFrame: rightFrame,
                   menuBarHeight: menuBarHeight, widgetWindows: rightWidgets
               ).origin,
               CGPoint(x: 3680, y: 1050))

        expect("Dropping onto a native widget moves to the nearest free slot",
               WindowSnapper.snappedFrame(
                   for: frame(4045, 1048),
                   screenFrame: rightFrame, visibleFrame: rightFrame,
                   menuBarHeight: menuBarHeight, widgetWindows: rightWidgets
               ).origin,
               CGPoint(x: 3680, y: 1050))

        // Widgets on other displays come first in the list and must be ignored.
        expect("Grid phase follows native widgets on the same display, not screen edges",
               WindowSnapper.snappedFrame(
                   for: frame(1370, 700),
                   screenFrame: primaryFrame, visibleFrame: primaryVisible,
                   menuBarHeight: menuBarHeight,
                   widgetWindows: rightWidgets + [CGRect(x: 1000, y: 700, width: 360, height: 360)]
               ).origin,
               CGPoint(x: 1368, y: 708))

        expect("Without widgets, bottom right snaps 16pt from the edge and above the Dock",
               WindowSnapper.snappedFrame(
                   for: frame(2200, 70),
                   screenFrame: primaryFrame, visibleFrame: primaryVisible,
                   menuBarHeight: menuBarHeight, widgetWindows: []
               ).origin,
               CGPoint(x: 2200, y: 72))

        expect("Without widgets, top left snaps 16pt from the edge and below the menu bar",
               WindowSnapper.snappedFrame(
                   for: frame(22, 1011),
                   screenFrame: primaryFrame, visibleFrame: primaryVisible,
                   menuBarHeight: menuBarHeight, widgetWindows: []
               ).origin,
               CGPoint(x: 16, y: 1050))

        // Native widgets keep the menu bar margin on displays without a menu
        // bar; the expected slot is exactly where the native large widget sits.
        expect("A display without a menu bar keeps the native top margin",
               WindowSnapper.snappedFrame(
                   for: frame(4750, 1030),
                   screenFrame: rightFrame, visibleFrame: rightFrame,
                   menuBarHeight: menuBarHeight, widgetWindows: []
               ).origin,
               CGPoint(x: 4760, y: 1050))

        let tinyScreen = CGRect(x: 0, y: 0, width: 380, height: 420)
        expect("When every slot is taken, the nearest slot is used anyway",
               WindowSnapper.snappedFrame(
                   for: frame(10, 50),
                   screenFrame: tinyScreen, visibleFrame: tinyScreen,
                   menuBarHeight: 0,
                   widgetWindows: [CGRect(x: 8, y: 52, width: 360, height: 360)]
               ).origin,
               CGPoint(x: 16, y: 60))

        let smallScreen = CGRect(x: 0, y: 0, width: 300, height: 300)
        expect("A screen smaller than the window leaves the frame unchanged",
               WindowSnapper.snappedFrame(
                   for: frame(10, 10),
                   screenFrame: smallScreen, visibleFrame: smallScreen,
                   menuBarHeight: 0, widgetWindows: []
               ).origin,
               CGPoint(x: 10, y: 10))

        print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
