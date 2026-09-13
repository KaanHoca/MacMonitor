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

/// Background behind the SwiftUI content, one layer per render state, each
/// matched to native macOS 26 widgets from screen captures:
/// - Full-color: an opaque surface, white in Light and neutral gray in Dark.
/// - Glass: NSGlassEffectView following the window appearance, plus a dark
///   shade in Dark; the HUD material before macOS 26.
/// Hidden layers are removed from rendering so only one effect runs at a time.
final class WidgetBackgroundView: NSView {
    enum Style { case fullColor, glass }

    /// Full-color surfaces of native widgets, matched in screen captures:
    /// native dark widgets read 61 there, and a surface of sRGB 47 reads 61
    /// through the same display pipeline (sRGB 61 read 78).
    static let lightSurfaceColor = NSColor.white
    static let darkSurfaceColor = NSColor(srgbRed: 47 / 255, green: 47 / 255, blue: 47 / 255, alpha: 1)
    /// Dimmed native widgets in Dark are darker than bare dark glass (about
    /// 27 vs 50 over the same wallpaper); tinting the glass only lightens it,
    /// so a black shade over the glass closes the gap.
    static let darkGlassShade = NSColor.black.withAlphaComponent(0.45)

    private let content: NSView
    private let surface = NSView()
    private let material = NSVisualEffectView()   // glass fallback before macOS 26
    private var glass: NSView?
    private let shade = NSView()
    private(set) var style: Style = .fullColor

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)

        for layerView in [surface, shade] {
            layerView.wantsLayer = true
            layerView.layer?.cornerRadius = WidgetChrome.cornerRadius
            layerView.layer?.cornerCurve = .continuous
            layerView.layer?.masksToBounds = true
        }
        shade.layer?.backgroundColor = Self.darkGlassShade.cgColor

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
        layers.append(shade)
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
        surface.layer?.backgroundColor = (dark ? Self.darkSurfaceColor : Self.lightSurfaceColor).cgColor
        let nativeGlass = style == .glass && glass != nil
        let targets: [(NSView?, Bool)] = [
            (surface, style == .fullColor),
            (material, style == .glass && glass == nil),
            (glass, nativeGlass),
            (shade, nativeGlass && dark),
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
