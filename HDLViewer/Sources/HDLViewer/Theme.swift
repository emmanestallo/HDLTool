import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum ThemeID: String, CaseIterable, Identifiable {
    case darkModern, darkPlus, lightModern

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .darkModern: return "Dark Modern"
        case .darkPlus: return "Dark+"
        case .lightModern: return "Light Modern"
        }
    }

    var theme: Theme {
        switch self {
        case .darkModern: return .darkModern
        case .darkPlus: return .darkPlus
        case .lightModern: return .lightModern
        }
    }
}

/// Color tokens named after VS Code's theme keys.
struct Theme {
    var isDark: Bool

    var titleBar: Color
    var titleFG: Color
    var activityBar: Color
    var activityFG: Color
    var activityInactiveFG: Color
    var activityActiveBorder: Color
    var sidebar: Color
    var sidebarFG: Color
    var editor: Color
    var fg: Color
    var dimFG: Color
    var border: Color
    var rowSeparator: Color
    var tabBar: Color
    var tabActive: Color
    var tabInactive: Color
    var tabActiveFG: Color
    var tabInactiveFG: Color
    var tabActiveBorder: Color
    var statusBar: Color
    var statusFG: Color
    var statusAccent: Color
    var statusAccentFG: Color
    var listSelection: Color
    var listHover: Color
    var inputBG: Color
    var inputBorder: Color
    var focusBorder: Color
    var accent: Color
    var buttonBG: Color
    var buttonFG: Color

    var wave1: Color
    var waveBus: Color
    var waveX: Color
    var waveZ: Color
    var waveText: Color
    var valueFG: Color
    var waveRowSelected: Color
    var cursor: Color
    var marker: Color
    var hoverLine: Color
    var grid: Color
    var rulerBG: Color
    var rulerFG: Color

    var palette: [(name: String, color: Color)]

    func color(for sig: DisplayedSignal) -> Color {
        if let i = sig.colorIndex, palette.indices.contains(i) { return palette[i].color }
        return sig.variable.trace.isBit ? wave1 : waveBus
    }

    func scopeColor(_ kind: String) -> Color {
        switch kind {
        case "module": return isDark ? Color(hex: 0xEE9D28) : Color(hex: 0xD67E00)
        case "task", "function": return isDark ? Color(hex: 0xB180D7) : Color(hex: 0x652D90)
        default: return isDark ? Color(hex: 0x75BEFF) : Color(hex: 0x007ACC)
        }
    }

    func varColor(_ kind: String) -> Color {
        switch kind {
        case "reg", "logic", "bit": return isDark ? Color(hex: 0xEE9D28) : Color(hex: 0xD67E00)
        case "integer", "int", "longint", "shortint", "byte": return isDark ? Color(hex: 0xB180D7) : Color(hex: 0x652D90)
        case "real", "realtime", "shortreal": return isDark ? Color(hex: 0xD16969) : Color(hex: 0xA31515)
        case "parameter": return isDark ? Color(hex: 0x4EC9B0) : Color(hex: 0x267F99)
        default: return isDark ? Color(hex: 0x75BEFF) : Color(hex: 0x007ACC)
        }
    }

    static let darkPalette: [(String, Color)] = [
        ("Teal", Color(hex: 0x4EC9B0)), ("Blue", Color(hex: 0x4FC1FF)), ("Green", Color(hex: 0x89D185)),
        ("Yellow", Color(hex: 0xDCDCAA)), ("Orange", Color(hex: 0xCE9178)), ("Red", Color(hex: 0xF48771)),
        ("Purple", Color(hex: 0xC586C0)), ("White", Color(hex: 0xD4D4D4)),
    ]

    static let darkModern = Theme(
        isDark: true,
        titleBar: Color(hex: 0x181818), titleFG: Color(hex: 0xCCCCCC),
        activityBar: Color(hex: 0x181818), activityFG: Color(hex: 0xD7D7D7),
        activityInactiveFG: Color(hex: 0x868686), activityActiveBorder: Color(hex: 0x0078D4),
        sidebar: Color(hex: 0x181818), sidebarFG: Color(hex: 0xCCCCCC),
        editor: Color(hex: 0x1F1F1F), fg: Color(hex: 0xCCCCCC), dimFG: Color(hex: 0x8B8B8B),
        border: Color(hex: 0x2B2B2B), rowSeparator: Color(hex: 0xFFFFFF, alpha: 0.035),
        tabBar: Color(hex: 0x181818), tabActive: Color(hex: 0x1F1F1F), tabInactive: Color(hex: 0x181818),
        tabActiveFG: Color(hex: 0xFFFFFF), tabInactiveFG: Color(hex: 0x9D9D9D), tabActiveBorder: Color(hex: 0x0078D4),
        statusBar: Color(hex: 0x181818), statusFG: Color(hex: 0xCCCCCC),
        statusAccent: Color(hex: 0x0078D4), statusAccentFG: .white,
        listSelection: Color(hex: 0x04395E), listHover: Color(hex: 0x2A2D2E),
        inputBG: Color(hex: 0x313131), inputBorder: Color(hex: 0x3C3C3C), focusBorder: Color(hex: 0x0078D4),
        accent: Color(hex: 0x0078D4), buttonBG: Color(hex: 0x0078D4), buttonFG: .white,
        wave1: Color(hex: 0x4EC9B0), waveBus: Color(hex: 0x4FC1FF), waveX: Color(hex: 0xF14C4C),
        waveZ: Color(hex: 0xCCA700), waveText: Color(hex: 0xE0E0E0), valueFG: Color(hex: 0xB5CEA8),
        waveRowSelected: Color(hex: 0xFFFFFF, alpha: 0.04),
        cursor: Color(hex: 0x3794FF), marker: Color(hex: 0xC586C0), hoverLine: Color(hex: 0xFFFFFF, alpha: 0.18),
        grid: Color(hex: 0xFFFFFF, alpha: 0.045), rulerBG: Color(hex: 0x181818), rulerFG: Color(hex: 0x9D9D9D),
        palette: darkPalette
    )

    static let darkPlus = Theme(
        isDark: true,
        titleBar: Color(hex: 0x3C3C3C), titleFG: Color(hex: 0xCCCCCC),
        activityBar: Color(hex: 0x333333), activityFG: Color(hex: 0xFFFFFF),
        activityInactiveFG: Color(hex: 0x858585), activityActiveBorder: Color(hex: 0xFFFFFF),
        sidebar: Color(hex: 0x252526), sidebarFG: Color(hex: 0xCCCCCC),
        editor: Color(hex: 0x1E1E1E), fg: Color(hex: 0xD4D4D4), dimFG: Color(hex: 0x8B8B8B),
        border: Color(hex: 0x3C3C3C), rowSeparator: Color(hex: 0xFFFFFF, alpha: 0.035),
        tabBar: Color(hex: 0x252526), tabActive: Color(hex: 0x1E1E1E), tabInactive: Color(hex: 0x2D2D2D),
        tabActiveFG: Color(hex: 0xFFFFFF), tabInactiveFG: Color(hex: 0x969696), tabActiveBorder: Color(hex: 0x1E1E1E),
        statusBar: Color(hex: 0x007ACC), statusFG: .white,
        statusAccent: Color(hex: 0x16825D), statusAccentFG: .white,
        listSelection: Color(hex: 0x094771), listHover: Color(hex: 0x2A2D2E),
        inputBG: Color(hex: 0x3C3C3C), inputBorder: Color(hex: 0x3C3C3C), focusBorder: Color(hex: 0x007FD4),
        accent: Color(hex: 0x007ACC), buttonBG: Color(hex: 0x0E639C), buttonFG: .white,
        wave1: Color(hex: 0x6A9955), waveBus: Color(hex: 0x569CD6), waveX: Color(hex: 0xF44747),
        waveZ: Color(hex: 0xD7BA7D), waveText: Color(hex: 0xD4D4D4), valueFG: Color(hex: 0xB5CEA8),
        waveRowSelected: Color(hex: 0xFFFFFF, alpha: 0.04),
        cursor: Color(hex: 0xDCDCAA), marker: Color(hex: 0xC586C0), hoverLine: Color(hex: 0xFFFFFF, alpha: 0.18),
        grid: Color(hex: 0xFFFFFF, alpha: 0.045), rulerBG: Color(hex: 0x252526), rulerFG: Color(hex: 0x969696),
        palette: darkPalette
    )

    static let lightModern = Theme(
        isDark: false,
        titleBar: Color(hex: 0xF8F8F8), titleFG: Color(hex: 0x1E1E1E),
        activityBar: Color(hex: 0xF8F8F8), activityFG: Color(hex: 0x1F1F1F),
        activityInactiveFG: Color(hex: 0x616161), activityActiveBorder: Color(hex: 0x005FB8),
        sidebar: Color(hex: 0xF8F8F8), sidebarFG: Color(hex: 0x3B3B3B),
        editor: Color(hex: 0xFFFFFF), fg: Color(hex: 0x3B3B3B), dimFG: Color(hex: 0x868686),
        border: Color(hex: 0xE5E5E5), rowSeparator: Color(hex: 0x000000, alpha: 0.04),
        tabBar: Color(hex: 0xF8F8F8), tabActive: Color(hex: 0xFFFFFF), tabInactive: Color(hex: 0xF8F8F8),
        tabActiveFG: Color(hex: 0x3B3B3B), tabInactiveFG: Color(hex: 0x868686), tabActiveBorder: Color(hex: 0x005FB8),
        statusBar: Color(hex: 0xF8F8F8), statusFG: Color(hex: 0x3B3B3B),
        statusAccent: Color(hex: 0x005FB8), statusAccentFG: .white,
        listSelection: Color(hex: 0xE8E8E8), listHover: Color(hex: 0xF2F2F2),
        inputBG: Color(hex: 0xFFFFFF), inputBorder: Color(hex: 0xCECECE), focusBorder: Color(hex: 0x005FB8),
        accent: Color(hex: 0x005FB8), buttonBG: Color(hex: 0x005FB8), buttonFG: .white,
        wave1: Color(hex: 0x16825D), waveBus: Color(hex: 0x0451A5), waveX: Color(hex: 0xE51400),
        waveZ: Color(hex: 0xBF8803), waveText: Color(hex: 0x1F1F1F), valueFG: Color(hex: 0x098658),
        waveRowSelected: Color(hex: 0x000000, alpha: 0.035),
        cursor: Color(hex: 0x005FB8), marker: Color(hex: 0xAF00DB), hoverLine: Color(hex: 0x000000, alpha: 0.18),
        grid: Color(hex: 0x000000, alpha: 0.05), rulerBG: Color(hex: 0xF8F8F8), rulerFG: Color(hex: 0x616161),
        palette: [
            ("Teal", Color(hex: 0x16825D)), ("Blue", Color(hex: 0x0451A5)), ("Green", Color(hex: 0x388A34)),
            ("Yellow", Color(hex: 0x8A6D00)), ("Orange", Color(hex: 0xC2410C)), ("Red", Color(hex: 0xCD3131)),
            ("Purple", Color(hex: 0xAF00DB)), ("Black", Color(hex: 0x1F1F1F)),
        ]
    )
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .darkModern
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

enum UI {
    static let rowHeight: CGFloat = 26
    static let uiFont = Font.system(size: 13)
    static let smallFont = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

/// The macOS 27 SDK declares `@State` as a macro whose plugin ships only with Xcode.
/// Referring to the property wrapper through an alias lets this build with Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
