# Widget Appearance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MacMonitor widget match native macOS 26 desktop widgets in light, dark and dimmed glass states, with Appearance and Widget Style menus and native continuous corners.

**Architecture:** A pure `DesktopFocusRule` decides from a front-to-back window list whether a click or app activation reveals the desktop (full-color) or dims it. `WidgetAppearance` persists the two menu choices, tracks the native state event by event and publishes whether the widget is glass. `WidgetBackgroundView` swaps between a light surface, the dark HUD material and `NSGlassEffectView`; SwiftUI colors follow the window appearance through `.primary` and per-state theme colors.

**Tech Stack:** Swift 6.3, SwiftUI and AppKit, plain `swiftc` builds (no Xcode project), macOS 13.0 deployment target, macOS 26.5 SDK.

**Spec:** `docs/superpowers/specs/2026-09-13-widget-appearance-design.md`

## Global Constraints

- Deployment target stays macOS 13.0; every macOS 26 API (`NSGlassEffectView`) sits behind `if #available(macOS 26.0, *)`.
- No new dependencies. Build with `./build.sh`; unit tests with `./test.sh`.
- Code and comments in English; no em dashes or en dashes anywhere (code, docs, commit messages).
- Commits carry no Claude attribution (project CLAUDE.md rule). Do not push; pushing is decided by the user at the end.
- Never post synthetic mouse or keyboard events for verification; ask the user to perform interactions.
- No test-only flags in the app. Layout variants are checked with throwaway builds outside the repo.
- Event-driven only: no new repeating timers or polling.
- UserDefaults keys: `appearanceMode` (`auto`, `light`, `dark`), `widgetStyle` (`auto`, `fullColor`, `glass`). Menu titles: `Appearance` with `Automatic`, `Light`, `Dark`; `Widget Style` with `Automatic`, `Full-color`, `Glass`.
- Corner radius 27.5pt, continuous, everywhere.
- SourceKit errors about cross-file symbols are false positives; `swiftc` is the truth.

## Verification Helpers

Create once per shell session; every task's visual checks use them.

```bash
V=$(mktemp -d "${TMPDIR:-/tmp}/mm-verify.XXXX")
cat > "$V/winid.swift" <<'EOF'
import CoreGraphics
// Prints "id x y width height" (CG coordinates) for each MacMonitor window.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "MacMonitor" {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print("\(w[kCGWindowNumber as String] ?? 0) \(b["X"] ?? 0) \(b["Y"] ?? 0) \(b["Width"] ?? 0) \(b["Height"] ?? 0)")
}
EOF
relaunch() { pkill -x MacMonitor; sleep 1; open /Users/karcael/Desktop/MacMonitor/MacMonitor.app "$@"; sleep 4; }
capture() { id=$(swift "$V/winid.swift" | head -1 | cut -d' ' -f1); screencapture -x -o -l "$id" "$V/$1.png"; }
```

`capture` grabs only the widget window (no backdrop). Glass needs a region capture (`screencapture -x -R x,y,w,h`) of an area no app window covers. The terminal host has Screen Recording permission.

---

### Task 1: Native Corner Shape

**Files:**
- Create: `MacMonitor/WidgetChrome.swift`
- Create: `Tests/WidgetChromeTests.swift`
- Modify: `test.sh` (run several suites)
- Modify: `build.sh`, `Install and Run.command` (compile the new file)
- Modify: `MacMonitor/MacMonitorApp.swift` (use the new mask, delete `roundedMask`)

**Interfaces:**
- Produces: `enum WidgetChrome { static let cornerRadius: CGFloat; static func cornerMask(radius: CGFloat = cornerRadius) -> NSImage }`

- [ ] **Step 1: Make test.sh run one executable per suite**

Replace the whole file:

```bash
#!/bin/bash
# MacMonitor: build and run the unit tests (plain swiftc, no Xcode project)
set -e

cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# Each suite is a standalone executable: the code under test plus its tests.
run_suite() {
  local name=$1
  shift
  swiftc -parse-as-library -o "$OUT/$name" "$@"
  "$OUT/$name"
}

run_suite WindowSnapperTests MacMonitor/WindowSnapper.swift Tests/WindowSnapperTests.swift
run_suite WidgetChromeTests MacMonitor/WidgetChrome.swift Tests/WidgetChromeTests.swift
```

- [ ] **Step 2: Write the failing test**

`Tests/WidgetChromeTests.swift`:

```swift
import AppKit

// Corner shape tests: the widget mask must match the corner profile of a
// native macOS 26 large widget, measured @2x from a window capture on the
// target Mac. Run with ./test.sh.

@main
struct WidgetChromeTests {
    static var failures = 0

    static func expect(_ name: String, _ got: Double, _ want: Double, tolerance: Double) {
        if abs(got - want) <= tolerance {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name): got \(got), want \(want) +/- \(tolerance)")
        }
    }

    /// Diagonal inset and the first opaque x (pt) on the given rows of the
    /// top-left corner, for the mask drawn into a width x height frame at 2x.
    static func cornerProfile(width: CGFloat, height: CGFloat, rows: [Int]) -> (diagonal: Double, xs: [Double]) {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        WidgetChrome.cornerMask().draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        // colorAt uses a top-left origin, so row 0 is the top edge.
        func opaque(_ x: Int, _ y: Int) -> Bool { (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
        var d = 0
        while !opaque(d, d) && d < 200 { d += 1 }
        let xs = rows.map { row -> Double in
            var x = 0
            while !opaque(x, row * 2) && x < 200 { x += 1 }
            return Double(x) / 2
        }
        return (Double(d) / 2, xs)
    }

    static func main() {
        let rows = [0, 1, 2, 4, 6, 8, 12, 16, 20, 24]
        let native: [Double] = [28.0, 20.5, 17.0, 13.0, 10.0, 8.0, 4.5, 2.5, 1.5, 0.5]

        // The grid square and the taller detail frame stretch the same mask.
        for (label, height) in [("grid 344x344", CGFloat(344)), ("detail 344x440", CGFloat(440))] {
            let profile = cornerProfile(width: 344, height: height, rows: rows)
            expect("\(label): diagonal inset matches native", profile.diagonal, 8.0, tolerance: 0.5)
            for (i, row) in rows.enumerated() {
                expect("\(label): row \(row) matches native", profile.xs[i], native[i], tolerance: 1.0)
            }
        }

        print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 3: Move the current circular mask into WidgetChrome unchanged (red baseline)**

`MacMonitor/WidgetChrome.swift`:

```swift
import AppKit
import SwiftUI

/// Window chrome shared by every widget state.
enum WidgetChrome {
    static let cornerRadius: CGFloat = 18

    /// Stretchable mask image for NSVisualEffectView.maskImage.
    static func cornerMask(radius: CGFloat = cornerRadius) -> NSImage {
        let edge = 2.0 * radius + 1.0
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
```

- [ ] **Step 4: Run the tests and watch the corner suite fail**

Run: `./test.sh`
Expected: WindowSnapperTests all PASS, then WidgetChromeTests FAIL lines such as `grid 344x344: row 0 matches native: got 16.0, want 28.0` and a non-zero exit.

- [ ] **Step 5: Implement the continuous corner**

Replace the body of `WidgetChrome.swift`:

```swift
import AppKit
import SwiftUI

/// Window chrome shared by every widget state.
enum WidgetChrome {
    /// Continuous corners measured to match native macOS 26 desktop widgets
    /// within 0.5pt; the earlier 18pt circular corners looked sharper.
    static let cornerRadius: CGFloat = 27.5

    /// Stretchable mask image with continuous corners for
    /// NSVisualEffectView.maskImage.
    static func cornerMask(radius: CGFloat = cornerRadius) -> NSImage {
        // Continuous corners blend into the edges over about 1.53x the
        // radius, so the fixed cap must cover that span to stretch cleanly.
        let cap = (radius * 1.6).rounded(.up)
        let edge = 2 * cap + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `./test.sh`
Expected: both suites end with `All tests passed.`, exit 0.

- [ ] **Step 7: Use the new mask in the window**

In `MacMonitor/MacMonitorApp.swift` replace

```swift
        // Rounded corners via maskImage — no border artifacts
        visualEffect.maskImage = roundedMask(cornerRadius: 18)
```

with

```swift
        // Native continuous corners via maskImage (no border artifacts)
        visualEffect.maskImage = WidgetChrome.cornerMask()
```

and delete the whole `private func roundedMask(cornerRadius: CGFloat) -> NSImage { ... }` method.

In both `build.sh` and `Install and Run.command` add the file to the app compile list, after `MacMonitor/WindowSnapper.swift \`:

```bash
  MacMonitor/WidgetChrome.swift \
```

- [ ] **Step 8: Build and verify on screen**

Run: `./build.sh && relaunch && capture corners && swift "$V/winid.swift"`
Expected: build succeeds; the window is 344x344. Open `$V/corners.png`: corners are visibly rounder, matching the neighboring native widget.

- [ ] **Step 9: Commit**

```bash
git add MacMonitor/WidgetChrome.swift Tests/WidgetChromeTests.swift test.sh build.sh "Install and Run.command" MacMonitor/MacMonitorApp.swift
git commit -m "Match native widget corners with a 27.5pt continuous mask."
```

---

### Task 2: Desktop Focus Rule

**Files:**
- Create: `MacMonitor/DesktopFocusRule.swift`
- Create: `Tests/DesktopFocusRuleTests.swift`
- Modify: `test.sh`, `build.sh`, `Install and Run.command`

**Interfaces:**
- Produces:
  - `enum WindowOwner: Equatable { case finder, dock, windowServer, widgetHost, macMonitor, other }`
  - `struct WindowInfo: Equatable { let owner: WindowOwner; let layer: Int; let bounds: CGRect; let alpha: Double }` (bounds in CG coordinates)
  - `enum WidgetStateChange: Equatable { case fullColor, dimmed, unchanged, recheck }`
  - `DesktopFocusRule.classifyClick(at: CGPoint, display: CGRect, windows: [WindowInfo]) -> WidgetStateChange`
  - `DesktopFocusRule.appWindowVisible(on: CGRect, windows: [WindowInfo]) -> Bool`

- [ ] **Step 1: Register the suite in test.sh**

Append to `test.sh`:

```bash
run_suite DesktopFocusRuleTests MacMonitor/DesktopFocusRule.swift Tests/DesktopFocusRuleTests.swift
```

- [ ] **Step 2: Write the failing tests**

`Tests/DesktopFocusRuleTests.swift` (fixtures come from the observer logs on the target Mac; the widget sits on the right display):

```swift
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

        print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 3: Add a stub with the final API that always answers unchanged/false**

`MacMonitor/DesktopFocusRule.swift`:

```swift
import CoreGraphics

enum WindowOwner: Equatable {
    case finder, dock, windowServer, widgetHost, macMonitor, other
}

struct WindowInfo: Equatable {
    let owner: WindowOwner
    let layer: Int
    let bounds: CGRect
    let alpha: Double
}

enum WidgetStateChange: Equatable {
    case fullColor, dimmed, unchanged, recheck
}

enum DesktopFocusRule {
    static func classifyClick(at point: CGPoint, display: CGRect, windows: [WindowInfo]) -> WidgetStateChange {
        .unchanged
    }

    static func appWindowVisible(on display: CGRect, windows: [WindowInfo]) -> Bool {
        false
    }
}
```

- [ ] **Step 4: Run the tests and watch them fail**

Run: `./test.sh`
Expected: DesktopFocusRuleTests prints FAIL for the wallpaper, app window, overlay, layer 18 and visible window cases; exit non-zero. (Cases whose expected value is `unchanged` or `false` pass against the stub; they guard the real implementation.)

- [ ] **Step 5: Implement the rule**

Replace the body of `MacMonitor/DesktopFocusRule.swift`:

```swift
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
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `./test.sh`
Expected: all three suites print `All tests passed.`, exit 0.

- [ ] **Step 7: Compile the rule into the app and commit**

In both `build.sh` and `Install and Run.command` add after `MacMonitor/WidgetChrome.swift \`:

```bash
  MacMonitor/DesktopFocusRule.swift \
```

Run: `./build.sh`
Expected: build succeeds.

```bash
git add MacMonitor/DesktopFocusRule.swift Tests/DesktopFocusRuleTests.swift test.sh build.sh "Install and Run.command"
git commit -m "Add the desktop focus rule that mirrors native widget dimming."
```

---

### Task 3: Adaptive Palette

No visible change is expected in this task: the window still forces the dark appearance, so `.primary` resolves to white.

**Files:**
- Modify: `MacMonitor/Components.swift` (environment key, button chrome, `.primary`)
- Modify: `MacMonitor/ContentView.swift` (`.primary`, button chrome, theme resolution)
- Modify: `MacMonitor/SystemMonitor.swift` (per-state theme colors)

**Interfaces:**
- Produces:
  - `EnvironmentValues.widgetGlass: Bool` (default `false`)
  - `View.accentButtonChrome(_ tint: Color, fillOpacity: Double = 0.3) -> some View`
  - `AppTheme.colors(scheme: ColorScheme, glass: Bool) -> ThemeColors`

- [ ] **Step 1: Add the environment key and the shared button chrome**

Append to `MacMonitor/Components.swift`:

```swift
// MARK: - Render State

private struct WidgetGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the widget renders as glass (native widgets are dimmed).
    var widgetGlass: Bool {
        get { self[WidgetGlassKey.self] }
        set { self[WidgetGlassKey.self] = newValue }
    }
}

// MARK: - Accent Button Chrome

/// Label and fill of the accent-tinted buttons. Dark and Glass: white label
/// on a translucent tint (the original look). Light: tint-colored label on a
/// lighter tint, because white on a pale fill is unreadable on white.
struct AccentButtonChrome: ViewModifier {
    let tint: Color
    var fillOpacity: Double = 0.3
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let light = colorScheme == .light
        content
            .foregroundStyle(light ? tint : Color.white)
            .background(tint.opacity(light ? fillOpacity * 0.5 : fillOpacity))
    }
}

extension View {
    func accentButtonChrome(_ tint: Color, fillOpacity: Double = 0.3) -> some View {
        modifier(AccentButtonChrome(tint: tint, fillOpacity: fillOpacity))
    }
}
```

- [ ] **Step 2: Add per-state theme colors**

In `MacMonitor/SystemMonitor.swift` add `import AppKit` after `import Foundation`, and after the closing brace of `enum AppTheme` add:

```swift
extension AppTheme {
    /// Theme colors for the current render state. Dark keeps the original
    /// palette; Light deepens it for contrast on a white surface; Glass is
    /// monochrome white like dimmed native widgets.
    func colors(scheme: ColorScheme, glass: Bool) -> ThemeColors {
        if glass {
            return ThemeColors(ring: .white.opacity(0.9), accent: .white,
                               disk: .white.opacity(0.75), temp: .white.opacity(0.82))
        }
        guard scheme == .light else { return colors }
        if self == .mono {
            return ThemeColors(ring: .black.opacity(0.7), accent: .black.opacity(0.85),
                               disk: .black.opacity(0.55), temp: .black.opacity(0.62))
        }
        let base = colors
        return ThemeColors(ring: base.ring.deepened, accent: base.accent.deepened,
                           disk: base.disk.deepened, temp: base.temp.deepened)
    }
}

private extension Color {
    /// Same hue, a bit more saturated and darker: keeps the theme's identity
    /// while staying readable on a white surface.
    var deepened: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(hue: Double(c.hueComponent),
                     saturation: min(Double(c.saturationComponent) * 1.1, 1),
                     brightness: Double(c.brightnessComponent) * 0.78)
    }
}
```

- [ ] **Step 3: Convert hardcoded white to primary**

Run from the repo root:

```bash
sed -i '' -E 's/Color\.white\.opacity\(/Color.primary.opacity(/g; s/\.white\.opacity\(/.primary.opacity(/g' MacMonitor/ContentView.swift MacMonitor/Components.swift
```

Then in `MacMonitor/ContentView.swift`:

1. Replace `        case 4: return .red\n        default: return .white` with `        case 4: return .red\n        default: return .primary`.
2. Replace `    var infoDetailColor: Color = .white` with `    var infoDetailColor: Color = .primary`.
3. Replace `    private var tc: ThemeColors { monitor.theme.colors }` with:

```swift
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetGlass) private var widgetGlass
    private var tc: ThemeColors { monitor.theme.colors(scheme: colorScheme, glass: widgetGlass) }
```

- [ ] **Step 4: Move the five accent buttons to the shared chrome**

In `MacMonitor/ContentView.swift`:

1. `actionButton`: delete the two `.foregroundStyle(.white)` lines on the idle and running images and the one on the label `Text`, and replace

```swift
            .background(state == .done ? Color.green.opacity(0.3) : accent.opacity(0.3))
```

with

```swift
            .accentButtonChrome(state == .done ? .green : accent)
```

2. Boost button: delete the two `.foregroundStyle(.white)` lines on the `wind` and `fan.fill` images and the one on `Text(boostLabel)`, replace `.background(boostBackground)` with

```swift
                .accentButtonChrome(boostTint, fillOpacity: boostState == .failed ? 0.2 : 0.3)
```

and replace the `boostBackground` property with

```swift
    private var boostTint: Color {
        if boostState == .done { return .green }
        if boostState == .failed { return .orange }
        return accent
    }
```

3. Scan button: delete `.foregroundStyle(.white)` after the `HStack` and replace `.background(accent.opacity(0.3))` with `.accentButtonChrome(accent)`.
4. Done button (clean completion): delete `.foregroundStyle(.white)` and replace `.background(accent.opacity(0.3))` with `.accentButtonChrome(accent)`.
5. Clean button: delete `.foregroundStyle(.white)` and replace

```swift
                .background(cleaner.totalCleanableSize > 0 ? accent.opacity(0.4) : Color.primary.opacity(0.08))
```

with

```swift
                .accentButtonChrome(cleaner.totalCleanableSize > 0 ? accent : Color.primary,
                                    fillOpacity: cleaner.totalCleanableSize > 0 ? 0.4 : 0.08)
```

- [ ] **Step 5: Check that no hardcoded white is left in the views**

Run: `grep -n "white" MacMonitor/ContentView.swift`
Expected: no output.

Run: `grep -n "\.white" MacMonitor/Components.swift`
Expected: only the `Color.white` label in `AccentButtonChrome`.

- [ ] **Step 6: Build and confirm the dark look is unchanged**

Run: `./build.sh && relaunch && capture grid3 && relaunch --args -debugDetail ram && capture ram3 && relaunch --args -debugDetail fan && capture fan3 && relaunch`
Expected: build succeeds; `grid3.png`, `ram3.png` (Quick and Purge buttons) and `fan3.png` (Boost button) look identical to the dark design before this task.

- [ ] **Step 7: Commit**

```bash
git add MacMonitor/Components.swift MacMonitor/ContentView.swift MacMonitor/SystemMonitor.swift
git commit -m "Route widget colors through primary, per-state theme colors and a shared button chrome."
```

---

### Task 4: Render States and Menus

**Files:**
- Create: `MacMonitor/WidgetAppearance.swift`
- Modify: `MacMonitor/WidgetChrome.swift` (add `WidgetBackgroundView`)
- Modify: `MacMonitor/ContentView.swift` (add `WidgetRoot`)
- Modify: `MacMonitor/Components.swift` (glass-aware `TickGauge`)
- Modify: `MacMonitor/MacMonitorApp.swift` (window setup, apply state, menus)
- Modify: `build.sh`, `Install and Run.command`

**Interfaces:**
- Consumes: `WidgetChrome.cornerRadius`, `WidgetChrome.cornerMask()`, `EnvironmentValues.widgetGlass`, `AppTheme.colors(scheme:glass:)`
- Produces:
  - `enum AppearanceMode: String, CaseIterable { case auto, light, dark; var title: String }`
  - `enum WidgetStyleMode: String, CaseIterable { case auto, fullColor, glass; var title: String }`
  - `final class WidgetAppearance: ObservableObject` with `appearanceMode`, `styleMode`, `isGlass`, `windowAppearance: NSAppearance?`, `onChange: (() -> Void)?`, and the internal `nativeDimmed` / `resolve()` that Task 5 extends
  - `final class WidgetBackgroundView: NSView` with `init(content: NSView)` and `setStyle(_: WidgetBackgroundView.Style, animated: Bool)`; `enum Style { case fullColor, glass }`

- [ ] **Step 1: Create the appearance model**

`MacMonitor/WidgetAppearance.swift`:

```swift
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

    /// Window appearance: nil follows the system. Glass always renders dark
    /// content, because dimmed native widgets show white text.
    var windowAppearance: NSAppearance? {
        if isGlass { return NSAppearance(named: .darkAqua) }
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
}
```

- [ ] **Step 2: Add the background view**

Append to `MacMonitor/WidgetChrome.swift`:

```swift
/// Background behind the SwiftUI content, one layer per render state:
/// Full-color Light shows an opaque light surface like native light widgets,
/// Full-color Dark the dark HUD material (the original look), and Glass
/// NSGlassEffectView on macOS 26 or the HUD material before it. Hidden
/// layers are removed from rendering so only one effect runs at a time.
final class WidgetBackgroundView: NSView {
    enum Style { case fullColor, glass }

    /// Native light widgets render on white (sampled from a screen capture).
    static let lightSurfaceColor = NSColor.white

    private let surface = NSView()
    private let material = NSVisualEffectView()
    private var glass: NSView?
    private(set) var style: Style = .fullColor

    init(content: NSView) {
        super.init(frame: .zero)

        surface.wantsLayer = true
        surface.layer?.backgroundColor = Self.lightSurfaceColor.cgColor
        surface.layer?.cornerRadius = WidgetChrome.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true

        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = WidgetChrome.cornerMask()

        var layers: [NSView] = [surface, material]
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.style = .clear
            glassView.cornerRadius = WidgetChrome.cornerRadius
            glass = glassView
            layers.append(glassView)
        }
        for view in layers + [content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        updateLayers(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setStyle(_ newStyle: Style, animated: Bool) {
        guard newStyle != style else { return }
        style = newStyle
        updateLayers(animated: animated)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers(animated: false)
    }

    private func updateLayers(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let targets: [(NSView?, Bool)] = [
            (surface, style == .fullColor && !dark),
            (material, (style == .fullColor && dark) || (style == .glass && glass == nil)),
            (glass, style == .glass && glass != nil),
        ]
        for (view, visible) in targets where visible { view?.isHidden = false }

        let hideFaded = {
            for (view, visible) in targets where !visible { view?.isHidden = true }
            self.window?.invalidateShadow()
        }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                for (view, visible) in targets { view?.animator().alphaValue = visible ? 1 : 0 }
            }, completionHandler: hideFaded)
        } else {
            for (view, visible) in targets { view?.alphaValue = visible ? 1 : 0 }
            hideFaded()
        }
    }
}
```

- [ ] **Step 3: Make TickGauge monochrome in Glass**

In `MacMonitor/Components.swift`, inside `struct TickGauge`, add after `var highlight: Bool = false`:

```swift
    @Environment(\.widgetGlass) private var glass
```

Replace

```swift
            let activeColor: Color = {
                if let crit = critAt, clamped >= crit { return Color(red: 0.90, green: 0.30, blue: 0.30) }
                if let warn = warnAt, clamped >= warn { return Color(red: 0.95, green: 0.65, blue: 0.30) }
                return color
            }()
```

with

```swift
            let pastWarn = warnAt.map { clamped >= $0 } ?? false
            let pastCrit = critAt.map { clamped >= $0 } ?? false
            let activeColor: Color = {
                if glass { return .white }
                if pastCrit { return Color(red: 0.90, green: 0.30, blue: 0.30) }
                if pastWarn { return Color(red: 0.95, green: 0.65, blue: 0.30) }
                return color
            }()
            // Glass is monochrome like dimmed native widgets; warning and
            // critical ticks stay distinguishable by burning brighter.
            let peak = glass && !pastWarn && !pastCrit ? 0.7 : 1.0
```

and replace `tickColor = activeColor.opacity(ramp * fill + 0.09 * (1 - fill))` with `tickColor = activeColor.opacity(peak * ramp * fill + 0.09 * (1 - fill))`.

- [ ] **Step 4: Add the SwiftUI root**

Append to `MacMonitor/ContentView.swift`:

```swift
// MARK: - Widget Root

/// Root of the widget: publishes the render state to the view tree and
/// desaturates everything in Glass, where native widgets are monochrome.
struct WidgetRoot: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var appearance: WidgetAppearance

    var body: some View {
        ContentView(monitor: monitor)
            .environment(\.widgetGlass, appearance.isGlass)
            .saturation(appearance.isGlass ? 0 : 1)
    }
}
```

- [ ] **Step 5: Rebuild the window around the background view**

In `MacMonitor/MacMonitorApp.swift`:

1. Add properties next to `let monitor = SystemMonitor()`:

```swift
    let widgetAppearance = WidgetAppearance()
    private var background: WidgetBackgroundView!
```

2. The content is attached last in `applicationDidFinishLaunching` (after placement and observer registration, see commit "Attach the widget content only after the window is placed"). Keep the `// Content goes in last: ...` comment and replace everything after it, from `let visualEffect = NSVisualEffectView(...)` through `window.contentView = visualEffect`, with:

```swift
        // SwiftUI content, sharing the same monitor instance
        let hosting = NSHostingView(rootView: WidgetRoot(monitor: monitor, appearance: widgetAppearance))
        // AppDelegate owns the window size (fixed widget grid sizes); without
        // this the SwiftUI content's ideal size silently overrides it.
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        background = WidgetBackgroundView(content: hosting)
        window.contentView = background
```

3. Right after `window.contentView = background` (before `window.orderFrontRegardless()`) add:

```swift
        widgetAppearance.onChange = { [weak self] in self?.applyWidgetAppearance(animated: true) }
        applyWidgetAppearance(animated: false)
```

4. Add the method in the Window Placement section:

```swift
    /// Pushes the resolved render state to the window: the NSAppearance
    /// drives SwiftUI's color scheme and the background swaps layers.
    private func applyWidgetAppearance(animated: Bool) {
        window.appearance = widgetAppearance.windowAppearance
        background.setStyle(widgetAppearance.isGlass ? .glass : .fullColor, animated: animated)
    }
```

- [ ] **Step 6: Add the Appearance and Widget Style menus**

In `setupStatusBar()`, replace the Theme submenu block (from `// Theme submenu` through `menu.addItem(themeItem)`) with:

```swift
        menu.addItem(makeChoiceMenu(
            title: "Theme", symbol: "paintpalette",
            choices: AppTheme.allCases.map { ($0.rawValue, $0.rawValue) },
            selected: monitor.theme.rawValue, action: #selector(themeSelected(_:))
        ))
```

After `menu.addItem(widgetRowsItem)` add:

```swift
        menu.addItem(makeChoiceMenu(
            title: "Appearance", symbol: "circle.lefthalf.filled",
            choices: AppearanceMode.allCases.map { ($0.title, $0.rawValue) },
            selected: widgetAppearance.appearanceMode.rawValue, action: #selector(appearanceSelected(_:))
        ))
        menu.addItem(makeChoiceMenu(
            title: "Widget Style", symbol: "rectangle.on.rectangle",
            choices: WidgetStyleMode.allCases.map { ($0.title, $0.rawValue) },
            selected: widgetAppearance.styleMode.rawValue, action: #selector(widgetStyleSelected(_:))
        ))
```

Add these helpers next to `makeWidgetRowItem`:

```swift
    /// Submenu with one checkmarked choice; items carry the raw value.
    private func makeChoiceMenu(
        title: String, symbol: String, choices: [(title: String, value: String)],
        selected: String, action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.image?.size = NSSize(width: 14, height: 14)
        let submenu = NSMenu()
        for choice in choices {
            let entry = NSMenuItem(title: choice.title, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.value
            entry.state = choice.value == selected ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func markSelected(_ sender: NSMenuItem) {
        for item in sender.menu?.items ?? [] {
            item.state = item === sender ? .on : .off
        }
    }
```

Replace the body of `themeSelected(_:)` with:

```swift
        guard let rawValue = sender.representedObject as? String,
              let theme = AppTheme(rawValue: rawValue) else { return }
        monitor.theme = theme
        markSelected(sender)
```

Add the two actions next to it:

```swift
    @objc private func appearanceSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppearanceMode(rawValue: raw) else { return }
        widgetAppearance.appearanceMode = mode
        markSelected(sender)
    }

    @objc private func widgetStyleSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WidgetStyleMode(rawValue: raw) else { return }
        widgetAppearance.styleMode = mode
        markSelected(sender)
    }
```

In both `build.sh` and `Install and Run.command` add after `MacMonitor/DesktopFocusRule.swift \`:

```bash
  MacMonitor/WidgetAppearance.swift \
```

- [ ] **Step 7: Build and check all three looks**

Run: `./build.sh`
Expected: build succeeds with no errors.

Record the user's slot first, then check each fixed mode:

```bash
OX=$(defaults read com.local.MacMonitor windowX); OY=$(defaults read com.local.MacMonitor windowY)
defaults write com.local.MacMonitor widgetStyle fullColor
defaults write com.local.MacMonitor appearanceMode light; relaunch; capture light4
defaults write com.local.MacMonitor appearanceMode dark; relaunch; capture dark4
relaunch --args -debugDetail ram; capture dark4ram
defaults write com.local.MacMonitor appearanceMode light; relaunch --args -debugDetail ram; capture light4ram
```

Expected: `light4.png` white surface, dark text, deepened theme ticks, readable faint unlit ticks; `light4ram.png` Quick and Purge readable (tinted labels); `dark4*.png` identical to the original dark design.

Glass needs the wallpaper behind it and no app window in front of it. Move the widget to a free slot next to the native widgets for the comparison (right display, below the Reminders widgets), with Terminal in front so native widgets are dimmed:

```bash
defaults write com.local.MacMonitor windowX -float 4040; defaults write com.local.MacMonitor windowY -float 330
defaults write com.local.MacMonitor widgetStyle glass; relaunch
screencapture -x -R3660,30,1460,1100 "$V/glass4.png"
```

Expected: in `glass4.png` MacMonitor (lower left of the native column) shows refracted wallpaper and white monochrome content like the dimmed native widgets. If the glass is visibly lighter or darker than the natives, switch `glassView.style` between `.clear` and `.regular` in `WidgetBackgroundView`, rebuild and capture again; keep the closer match.

Check a detail view in Glass as well (it grows downward from the same slot):

```bash
relaunch --args -debugDetail ram
screencapture -x -R3660,30,1460,1100 "$V/glass4ram.png"
```

Expected: the Memory detail is readable in white on glass; Quick and Purge show white labels on a translucent white fill.

Ask the user to click an empty spot of the wallpaper on the right display within 15 seconds, then run:

```bash
defaults write com.local.MacMonitor widgetStyle fullColor; defaults write com.local.MacMonitor appearanceMode auto; relaunch
sleep 15; screencapture -x -R3660,30,1460,1100 "$V/full4.png"
```

Expected: native widgets and MacMonitor are both on white in `full4.png`. Sample an empty spot of a native widget in `full4.png`; if it is not pure white, set `WidgetBackgroundView.lightSurfaceColor` to that color.

Restore the user's settings:

```bash
defaults write com.local.MacMonitor windowX -float "$OX"; defaults write com.local.MacMonitor windowY -float "$OY"
defaults write com.local.MacMonitor widgetStyle auto; defaults write com.local.MacMonitor appearanceMode auto; relaunch
```

- [ ] **Step 8: Run the unit tests and commit**

Run: `./test.sh`
Expected: all suites pass (WidgetChrome.swift now also compiles the background view).

```bash
git add MacMonitor/WidgetAppearance.swift MacMonitor/WidgetChrome.swift MacMonitor/ContentView.swift MacMonitor/Components.swift MacMonitor/MacMonitorApp.swift build.sh "Install and Run.command"
git commit -m "Add light, dark and glass render states with Appearance and Widget Style menus."
```

---

### Task 5: Automatic Tracking

**Files:**
- Modify: `MacMonitor/WidgetAppearance.swift`
- Modify: `MacMonitor/MacMonitorApp.swift`

**Interfaces:**
- Consumes: `DesktopFocusRule.classifyClick`, `DesktopFocusRule.appWindowVisible`, `WindowInfo`, `WindowOwner`, `WidgetAppearance.nativeDimmed`, `WidgetAppearance.resolve()`
- Produces: `WidgetAppearance.startTracking(window: NSWindow)`

- [ ] **Step 1: Add event-driven tracking to WidgetAppearance**

Add to `final class WidgetAppearance` (below `resolve()`):

```swift
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
```

Change the `styleMode` observer so switching back to Automatic re-reads the screen:

```swift
    @Published var styleMode: WidgetStyleMode {
        didSet {
            UserDefaults.standard.set(styleMode.rawValue, forKey: Key.style)
            if styleMode == .auto { refreshFromVisibleWindows() }
            resolve()
        }
    }
```

- [ ] **Step 2: Start tracking once the window exists**

In `MacMonitor/MacMonitorApp.swift`, after `applyWidgetAppearance(animated: false)` add:

```swift
        widgetAppearance.startTracking(window: window)
```

- [ ] **Step 3: Build and check for permission prompts**

Run: `./build.sh && ./test.sh && relaunch`
Expected: build and tests pass. Ask the user whether any permission dialog appeared at launch. If one did, remove the global click monitor (keep activation and display rules), note it in the spec's Permissions section, rebuild and relaunch.

- [ ] **Step 4: Verify the behavior with the user**

Ask the user to perform, with about 3 seconds between steps, while watching MacMonitor next to the native widgets on the same display:

1. Click an empty spot of the wallpaper (windows slide away): both switch to full-color.
2. Click MacMonitor's edge: nothing changes.
3. Click a parked window's visible edge so windows return: both dim.
4. Cmd+Tab to an app on another display: nothing changes.
5. Click the wallpaper again: both full-color. Then Cmd+Tab to an app whose window is on this display: both dim.

Expected: MacMonitor switches together with the native widgets at every step. Record any step where it does not, with what the native widgets did.

- [ ] **Step 5: Commit**

```bash
git add MacMonitor/WidgetAppearance.swift MacMonitor/MacMonitorApp.swift
git commit -m "Follow the native widgets' dimmed state from clicks and app activations."
```

---

### Task 6: Documentation, Resources and Release

**Files:**
- Modify: `architecture.md`, `README.md`, `memory.md`
- Modify: `docs/superpowers/specs/2026-09-13-widget-appearance-design.md` (only if Task 4 or 5 changed a decision)

- [ ] **Step 1: Measure resource use**

Run: `PID=$(pgrep -x MacMonitor); top -l 7 -s 5 -pid $PID -stats pid,cpu,mem,threads | grep -E "^$PID"`
Expected: CPU around the previous release (1.5 to 1.6 percent in full-color), memory near 83 to 85 MB, 8 threads. Repeat once in Glass (`defaults write com.local.MacMonitor widgetStyle glass; relaunch`) and restore `auto` afterwards. Report the numbers as measured, including any increase from the glass effect.

- [ ] **Step 2: Update architecture.md**

Add a `## Widget Appearance` section after `## Widget Grid Placement` describing: the three render states and their backgrounds (`WidgetBackgroundView`), `WidgetAppearance` (keys `appearanceMode`, `widgetStyle`, `windowAppearance`, glass forcing dark content), `DesktopFocusRule` (the measured rule table, click and activation rules, the 0.7s recheck, known limits), `.primary` colors with `AccentButtonChrome` and per-state `ThemeColors`, the 27.5pt continuous corners, and the macOS 13 to 25 fallback. Update the Source Layout tree with `WidgetChrome.swift`, `DesktopFocusRule.swift`, `WidgetAppearance.swift` and the two new test files, and the Build section's file list.

- [ ] **Step 3: Update README.md**

Features: add "Matches Native Widgets" (light and dark appearance, dimmed glass state, native corners). Usage table: add `Appearance` and `Widget Style` rows (Menu bar icon > **Appearance** / **Widget Style**). Project Structure: add the three new source files and two test files.

- [ ] **Step 4: Update memory.md**

Add a Turkish section at the top ("Eylül 2026: Açık, Koyu ve Cam Görünüm") with: the measured native state rule, the observer method, the permission lesson (the session host lacked Screen Recording; an observer triggered a prompt; ask before running anything that can prompt), the corner measurement, the decisions (monochrome glass including warnings, Widget Style mirror, event-driven detection and its limits), and the verification results from Tasks 4 and 5.

- [ ] **Step 5: Commit**

```bash
git add architecture.md README.md memory.md docs/superpowers/specs/2026-09-13-widget-appearance-design.md
git commit -m "Document the light, dark and glass widget appearance."
```

- [ ] **Step 6: Hand off**

Report to the user in Turkish: what changed, test and build results, the side-by-side captures, resource numbers, and anything that did not match. Ask whether to install to /Applications and push.
