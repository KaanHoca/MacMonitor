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

    /// Window appearance: nil follows the system. It also tints the glass,
    /// which is light in Light like dimmed native widgets; the glass content
    /// itself is forced dark by WidgetBackgroundView.
    var windowAppearance: NSAppearance? {
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
