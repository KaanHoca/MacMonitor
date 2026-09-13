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
