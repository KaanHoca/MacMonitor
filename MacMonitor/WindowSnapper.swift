import CoreGraphics

/// Snaps the widget window onto the macOS desktop widget grid so it lines up
/// with native widgets. Pure geometry in Cocoa coordinates (origin at the
/// bottom-left of the primary display, y grows upward); no AppKit state.
///
/// Native grid (measured on macOS 26): 180pt cells, 16pt gutters, so a large
/// widget is 344x344 visible. Widget windows are one cell per unit and carry a
/// transparent half-gutter (8pt) inset around the visible widget.
enum WindowSnapper {
    static let pitch: CGFloat = 180
    static let gutter: CGFloat = 16

    /// Converts CGWindowList bounds (origin top-left of the primary display,
    /// y grows downward) into Cocoa coordinates.
    static func cocoaRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Returns `frame` moved to the nearest grid slot on the given screen.
    /// Slots covered by native widgets are skipped unless every slot is taken;
    /// if the window cannot fit on the screen at all, `frame` is returned as is.
    static func snappedFrame(
        for frame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        menuBarHeight: CGFloat,
        widgetWindows: [CGRect]
    ) -> CGRect {
        let widgets = widgetWindows
            .filter { $0.intersects(screenFrame) }
            .map { $0.insetBy(dx: gutter / 2, dy: gutter / 2) }

        let (phaseX, phaseTop) = gridPhase(
            for: frame, screenFrame: screenFrame, visibleFrame: visibleFrame,
            menuBarHeight: menuBarHeight, widgets: widgets
        )

        let lefts = gridValues(phase: phaseX, from: visibleFrame.minX, to: visibleFrame.maxX - frame.width)
        let tops = gridValues(phase: phaseTop, from: visibleFrame.minY + frame.height, to: visibleFrame.maxY)
        guard !lefts.isEmpty, !tops.isEmpty else { return frame }

        let candidates = lefts.flatMap { x in
            tops.map { top in CGRect(x: x, y: top - frame.height, width: frame.width, height: frame.height) }
        }
        let free = candidates.filter { slot in !widgets.contains { $0.intersects(slot) } }

        // Distance is measured between top-left corners, the edge people align by.
        func distance(_ slot: CGRect) -> CGFloat {
            hypot(slot.minX - frame.minX, slot.maxY - frame.maxY)
        }
        let pool = free.isEmpty ? candidates : free
        return pool.min { distance($0) < distance($1) } ?? frame
    }

    /// Picks the grid alignment: native widgets on this screen define it when
    /// present; otherwise the grid hugs the screen edges nearest to the window,
    /// keeping a gutter from the edges and the menu bar like native widgets do.
    private static func gridPhase(
        for frame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        menuBarHeight: CGFloat,
        widgets: [CGRect]
    ) -> (x: CGFloat, top: CGFloat) {
        if let widget = widgets.first {
            return (widget.minX, widget.maxY)
        }

        let x = frame.midX >= visibleFrame.midX
            ? visibleFrame.maxX - pitch            // rightmost cell ends one gutter from the edge
            : visibleFrame.minX + gutter

        // Native widgets keep the menu bar margin even on displays without one.
        let topLine = min(visibleFrame.maxY, screenFrame.maxY - menuBarHeight) - gutter
        let top = frame.midY >= visibleFrame.midY
            ? topLine
            : visibleFrame.minY + pitch           // lowest cell starts one gutter above the bottom

        return (x, top)
    }

    /// All values `phase + k * pitch` inside the closed range `from...to`.
    private static func gridValues(phase: CGFloat, from lower: CGFloat, to upper: CGFloat) -> [CGFloat] {
        guard lower <= upper else { return [] }
        // A tiny tolerance keeps slots that sit exactly on a boundary.
        let tolerance: CGFloat = 1e-6
        let kMin = Int(((lower - phase) / pitch - tolerance).rounded(.up))
        let kMax = Int(((upper - phase) / pitch + tolerance).rounded(.down))
        guard kMin <= kMax else { return [] }
        return (kMin...kMax).map { phase + CGFloat($0) * pitch }
    }
}
