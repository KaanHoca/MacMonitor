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

/// Window background blur through the private CGS call that iTerm2 and kitty
/// use. NSGlassEffectView's blur is fixed and measured about three times
/// heavier than dimmed native widgets (sigma 20pt vs 6pt), so the glass is
/// built from this blur plus a tint and a rim instead. The symbols are looked
/// up at runtime; when they are missing the widget falls back to
/// NSGlassEffectView. The blur is clipped to the window's rounded shape.
enum WindowBackdropBlur {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let functions: (connection: MainConnection, setRadius: SetRadius)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let setRadius = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(setRadius, to: SetRadius.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// Blurs what is behind the window; returns false when unavailable or refused.
    @discardableResult
    static func setRadius(_ radius: Int, for window: NSWindow) -> Bool {
        guard let f = functions else { return false }
        return f.setRadius(f.connection(), Int32(window.windowNumber), Int32(radius)) == 0
    }
}

/// Background behind the SwiftUI content, one layer per render state, each
/// matched to native macOS 26 widgets from screen captures:
/// - Full-color: an opaque surface, white in Light and neutral gray in Dark.
/// - Glass: a window blur, a tint and a 1pt rim tuned to dimmed native
///   widgets. Without the blur call: NSGlassEffectView (plus a shade in
///   Dark), or the HUD material before macOS 26.
/// Hidden layers are removed from rendering so only one effect runs at a time.
final class WidgetBackgroundView: NSView {
    enum Style { case fullColor, glass }

    /// Full-color surfaces of native widgets, matched in screen captures:
    /// native dark widgets read 61 there, and a surface of sRGB 47 reads 61
    /// through the same display pipeline (sRGB 61 read 78).
    static let lightSurfaceColor = NSColor.white
    static let darkSurfaceColor = NSColor(srgbRed: 47 / 255, green: 47 / 255, blue: 47 / 255, alpha: 1)

    /// Dimmed native widgets blur the wallpaper with a sigma of about 6pt;
    /// radius 4, 8, 12 and 16 measured sigma 1.8, 2.7, 3.7 and 4.7pt.
    static let glassBlurRadius = 20
    /// Tints over the blurred wallpaper. In Dark, native dimmed widgets show
    /// about 0.33 of the wallpaper plus (13, 20, 27), which a 67% tint of
    /// (19, 30, 40) reproduces. The Light tint is an estimate from a single
    /// brightness sample (0.39 over a dark wallpaper) until measured.
    static let darkGlassTint = NSColor(srgbRed: 16 / 255, green: 23 / 255, blue: 31 / 255, alpha: 0.67)
    static let lightGlassTint = NSColor(srgbRed: 128 / 255, green: 132 / 255, blue: 140 / 255, alpha: 0.6)
    /// The 1pt rim of dimmed native widgets stands about 100 above the interior.
    static let glassRimColor = NSColor(white: 1, alpha: 0.42)
    /// Fallback only: dims NSGlassEffectView in Dark. Measured against the
    /// bare wallpaper, a navy shade at 52% matched native widgets within 3
    /// levels per channel; tinting the glass itself only lightened it.
    static let darkGlassShade = NSColor(srgbRed: 0, green: 5 / 255, blue: 12 / 255, alpha: 0.52)

    private let content: NSView
    private let surface = NSView()
    private let material = NSVisualEffectView()   // glass fallback before macOS 26
    private var glass: NSView?                     // glass fallback without the blur call
    private let shade = NSView()                   // tint over the blur, or shade over fallback glass
    private let rimView = NSView()
    private let rim = CAShapeLayer()
    private let customGlass = WindowBackdropBlur.isAvailable
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
        rimView.wantsLayer = true
        rim.fillColor = nil
        rim.lineWidth = 1
        rim.strokeColor = Self.glassRimColor.cgColor
        rimView.layer?.addSublayer(rim)

        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = WidgetChrome.cornerMask()

        var layers: [NSView] = [surface, material]
        if #available(macOS 26.0, *), !customGlass {
            let glassView = NSGlassEffectView()
            glassView.style = .clear
            glassView.cornerRadius = WidgetChrome.cornerRadius
            glass = glassView
            layers.append(glassView)
        }
        layers += [shade, rimView]
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayers(animated: false)
    }

    override func layout() {
        super.layout()
        // The rim follows the window height (grid 344, detail 440) at once.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = rimView.bounds
        rim.path = RoundedRectangle(cornerRadius: WidgetChrome.cornerRadius, style: .continuous)
            .path(in: rimView.bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        CATransaction.commit()
    }

    private func updateLayers(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        surface.layer?.backgroundColor = (dark ? Self.darkSurfaceColor : Self.lightSurfaceColor).cgColor
        let glassOn = style == .glass
        let blurGlass = glassOn && customGlass
        let fallbackGlass = glassOn && glass != nil
        let fallbackMaterial = glassOn && !customGlass && glass == nil
        shade.layer?.backgroundColor = (blurGlass ? (dark ? Self.darkGlassTint : Self.lightGlassTint) : Self.darkGlassShade).cgColor
        let targets: [(NSView?, Bool)] = [
            (surface, style == .fullColor),
            (material, fallbackMaterial),
            (glass, fallbackGlass),
            (shade, blurGlass || (fallbackGlass && dark)),
            (rimView, blurGlass),
        ]
        for (view, visible) in targets where visible { view?.isHidden = false }

        // Glass content is white like dimmed native widgets' content, so it
        // renders in the dark scheme whatever the window appearance is.
        let darkContent = glassOn ? NSAppearance(named: .darkAqua) : nil
        content.appearance = darkContent
        material.appearance = fallbackMaterial ? darkContent : nil

        // Native dimmed widgets have no drop shadow (it drew a dark outline).
        if let window = window {
            if customGlass { WindowBackdropBlur.setRadius(blurGlass ? Self.glassBlurRadius : 0, for: window) }
            window.hasShadow = !blurGlass
        }

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
