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

/// Background behind the SwiftUI content, one layer per render state:
/// Full-color Light shows an opaque light surface like native light widgets,
/// Full-color Dark the dark HUD material (the original look), and Glass
/// NSGlassEffectView on macOS 26 or the HUD material before it. Hidden
/// layers are removed from rendering so only one effect runs at a time.
final class WidgetBackgroundView: NSView {
    enum Style { case fullColor, glass }

    /// Native light widgets render on white (sampled from a screen capture).
    static let lightSurfaceColor = NSColor.white

    private let content: NSView
    private let surface = NSView()
    private let material = NSVisualEffectView()
    private var glass: NSView?
    private(set) var style: Style = .fullColor

    init(content: NSView) {
        self.content = content
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

        // Glass follows the window appearance (light glass in Light, measured
        // against dimmed native widgets: 0.40 vs 0.39 brightness over a dark
        // wallpaper), while its content is white like theirs.
        let darkContent = style == .glass ? NSAppearance(named: .darkAqua) : nil
        content.appearance = darkContent
        material.appearance = glass == nil ? darkContent : nil

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
