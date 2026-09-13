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
