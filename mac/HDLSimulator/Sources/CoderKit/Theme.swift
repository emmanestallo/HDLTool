import AppKit
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

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
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

    static var current: ThemeID {
        ThemeID(rawValue: UserDefaults.standard.string(forKey: "themeID") ?? "") ?? .darkModern
    }
}

/// Color tokens named after VS Code's theme keys (same palette as HDL Viewer and HDL Tester).
struct Theme {
    var id: ThemeID
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
    var secondaryButtonBG: Color
    var secondaryButtonFG: Color
    var widgetBG: Color

    var error: Color
    var warning: Color
    var success: Color
    var info: Color

    // Editor (NSColor because the editor is an NSTextView)
    var editorFG: UInt32
    var selection: UInt32
    var selectionAlpha: CGFloat = 1
    var lineHighlight: UInt32
    var lineHighlightAlpha: CGFloat
    var gutterFG: UInt32
    var gutterActiveFG: UInt32
    var caret: UInt32
    var wordHighlightAlpha: CGFloat
    var indentGuide: UInt32
    var indentGuideAlpha: CGFloat

    // Syntax colors (VS Code defaults)
    var synKeyword: Color { isDark ? Color(hex: 0x569CD6) : Color(hex: 0x0000FF) }
    var synControl: Color { isDark ? Color(hex: 0xC586C0) : Color(hex: 0xAF00DB) }
    var synType: Color { isDark ? Color(hex: 0x4EC9B0) : Color(hex: 0x267F99) }
    var synComment: Color { isDark ? Color(hex: 0x6A9955) : Color(hex: 0x008000) }
    var synNumber: Color { isDark ? Color(hex: 0xB5CEA8) : Color(hex: 0x098658) }
    var synString: Color { isDark ? Color(hex: 0xCE9178) : Color(hex: 0xA31515) }
    var synSystem: Color { isDark ? Color(hex: 0xDCDCAA) : Color(hex: 0x795E26) }
    var synDirective: Color { isDark ? Color(hex: 0xC586C0) : Color(hex: 0xAF00DB) }
    var synIdent: Color { isDark ? Color(hex: 0x9CDCFE) : Color(hex: 0x001080) }
    var lineNumber: Color { Color(hex: 0x6E7681) }

    func dirColor(_ d: String) -> Color {
        switch d {
        case "input", "in": return isDark ? Color(hex: 0x75BEFF) : Color(hex: 0x007ACC)
        case "output", "out", "buffer": return isDark ? Color(hex: 0xEE9D28) : Color(hex: 0xD67E00)
        default: return isDark ? Color(hex: 0xB180D7) : Color(hex: 0x652D90)
        }
    }

    func symbolColor(_ k: SymbolKind) -> Color {
        switch k {
        case .module, .entity, .interface, .program, .klass, .package, .architecture, .component:
            return isDark ? Color(hex: 0xEE9D28) : Color(hex: 0xD67E00)
        case .function, .task: return isDark ? Color(hex: 0xB180D7) : Color(hex: 0x652D90)
        case .port: return isDark ? Color(hex: 0x75BEFF) : Color(hex: 0x007ACC)
        case .param, .constant: return isDark ? Color(hex: 0x4FC1FF) : Color(hex: 0x0070C1)
        case .signal: return isDark ? Color(hex: 0x75BEFF) : Color(hex: 0x007ACC)
        case .instance: return isDark ? Color(hex: 0x4EC9B0) : Color(hex: 0x267F99)
        case .process: return isDark ? Color(hex: 0xC586C0) : Color(hex: 0xAF00DB)
        case .type: return isDark ? Color(hex: 0x4EC9B0) : Color(hex: 0x267F99)
        case .block: return dimFG
        }
    }

    static let darkModern = Theme(
        id: .darkModern, isDark: true,
        titleBar: Color(hex: 0x181818), titleFG: Color(hex: 0xCCCCCC),
        activityBar: Color(hex: 0x181818), activityFG: Color(hex: 0xD7D7D7),
        activityInactiveFG: Color(hex: 0x868686), activityActiveBorder: Color(hex: 0x0078D4),
        sidebar: Color(hex: 0x181818), sidebarFG: Color(hex: 0xCCCCCC),
        editor: Color(hex: 0x1F1F1F), fg: Color(hex: 0xCCCCCC), dimFG: Color(hex: 0x8B8B8B),
        border: Color(hex: 0x2B2B2B),
        tabBar: Color(hex: 0x181818), tabActive: Color(hex: 0x1F1F1F), tabInactive: Color(hex: 0x181818),
        tabActiveFG: Color(hex: 0xFFFFFF), tabInactiveFG: Color(hex: 0x9D9D9D), tabActiveBorder: Color(hex: 0x0078D4),
        statusBar: Color(hex: 0x181818), statusFG: Color(hex: 0xCCCCCC),
        statusAccent: Color(hex: 0x0078D4), statusAccentFG: .white,
        listSelection: Color(hex: 0x04395E), listHover: Color(hex: 0x2A2D2E),
        inputBG: Color(hex: 0x313131), inputBorder: Color(hex: 0x3C3C3C), focusBorder: Color(hex: 0x0078D4),
        accent: Color(hex: 0x0078D4), buttonBG: Color(hex: 0x0078D4), buttonFG: .white,
        secondaryButtonBG: Color(hex: 0x313131), secondaryButtonFG: Color(hex: 0xCCCCCC),
        widgetBG: Color(hex: 0x202020),
        error: Color(hex: 0xF14C4C), warning: Color(hex: 0xCCA700), success: Color(hex: 0x89D185), info: Color(hex: 0x3794FF),
        editorFG: 0xCCCCCC, selection: 0x264F78, lineHighlight: 0xFFFFFF, lineHighlightAlpha: 0.045,
        gutterFG: 0x6E7681, gutterActiveFG: 0xCCCCCC, caret: 0xAEAFAD, wordHighlightAlpha: 0.5,
        indentGuide: 0xFFFFFF, indentGuideAlpha: 0.07
    )

    static let darkPlus = Theme(
        id: .darkPlus, isDark: true,
        titleBar: Color(hex: 0x3C3C3C), titleFG: Color(hex: 0xCCCCCC),
        activityBar: Color(hex: 0x333333), activityFG: Color(hex: 0xFFFFFF),
        activityInactiveFG: Color(hex: 0x858585), activityActiveBorder: Color(hex: 0xFFFFFF),
        sidebar: Color(hex: 0x252526), sidebarFG: Color(hex: 0xCCCCCC),
        editor: Color(hex: 0x1E1E1E), fg: Color(hex: 0xD4D4D4), dimFG: Color(hex: 0x8B8B8B),
        border: Color(hex: 0x3C3C3C),
        tabBar: Color(hex: 0x252526), tabActive: Color(hex: 0x1E1E1E), tabInactive: Color(hex: 0x2D2D2D),
        tabActiveFG: Color(hex: 0xFFFFFF), tabInactiveFG: Color(hex: 0x969696), tabActiveBorder: Color(hex: 0x1E1E1E),
        statusBar: Color(hex: 0x007ACC), statusFG: .white,
        statusAccent: Color(hex: 0x16825D), statusAccentFG: .white,
        listSelection: Color(hex: 0x094771), listHover: Color(hex: 0x2A2D2E),
        inputBG: Color(hex: 0x3C3C3C), inputBorder: Color(hex: 0x3C3C3C), focusBorder: Color(hex: 0x007FD4),
        accent: Color(hex: 0x007ACC), buttonBG: Color(hex: 0x0E639C), buttonFG: .white,
        secondaryButtonBG: Color(hex: 0x3A3D41), secondaryButtonFG: Color(hex: 0xCCCCCC),
        widgetBG: Color(hex: 0x252526),
        error: Color(hex: 0xF44747), warning: Color(hex: 0xCCA700), success: Color(hex: 0x89D185), info: Color(hex: 0x3794FF),
        editorFG: 0xD4D4D4, selection: 0x264F78, lineHighlight: 0xFFFFFF, lineHighlightAlpha: 0.04,
        gutterFG: 0x858585, gutterActiveFG: 0xC6C6C6, caret: 0xAEAFAD, wordHighlightAlpha: 0.5,
        indentGuide: 0xFFFFFF, indentGuideAlpha: 0.08
    )

    static let lightModern = Theme(
        id: .lightModern, isDark: false,
        titleBar: Color(hex: 0xF8F8F8), titleFG: Color(hex: 0x1E1E1E),
        activityBar: Color(hex: 0xF8F8F8), activityFG: Color(hex: 0x1F1F1F),
        activityInactiveFG: Color(hex: 0x616161), activityActiveBorder: Color(hex: 0x005FB8),
        sidebar: Color(hex: 0xF8F8F8), sidebarFG: Color(hex: 0x3B3B3B),
        editor: Color(hex: 0xFFFFFF), fg: Color(hex: 0x3B3B3B), dimFG: Color(hex: 0x868686),
        border: Color(hex: 0xE5E5E5),
        tabBar: Color(hex: 0xF8F8F8), tabActive: Color(hex: 0xFFFFFF), tabInactive: Color(hex: 0xF8F8F8),
        tabActiveFG: Color(hex: 0x3B3B3B), tabInactiveFG: Color(hex: 0x868686), tabActiveBorder: Color(hex: 0x005FB8),
        statusBar: Color(hex: 0xF8F8F8), statusFG: Color(hex: 0x3B3B3B),
        statusAccent: Color(hex: 0x005FB8), statusAccentFG: .white,
        listSelection: Color(hex: 0xE8E8E8), listHover: Color(hex: 0xF2F2F2),
        inputBG: Color(hex: 0xFFFFFF), inputBorder: Color(hex: 0xCECECE), focusBorder: Color(hex: 0x005FB8),
        accent: Color(hex: 0x005FB8), buttonBG: Color(hex: 0x005FB8), buttonFG: .white,
        secondaryButtonBG: Color(hex: 0xE5E5E5), secondaryButtonFG: Color(hex: 0x3B3B3B),
        widgetBG: Color(hex: 0xF8F8F8),
        error: Color(hex: 0xE51400), warning: Color(hex: 0xBF8803), success: Color(hex: 0x388A34), info: Color(hex: 0x1A85FF),
        editorFG: 0x3B3B3B, selection: 0xADD6FF, lineHighlight: 0x000000, lineHighlightAlpha: 0.04,
        gutterFG: 0x6E7681, gutterActiveFG: 0x171184, caret: 0x000000, wordHighlightAlpha: 0.25,
        indentGuide: 0x000000, indentGuideAlpha: 0.1
    )
}

/// The syntax colors as NSColors for the text view.
struct SyntaxPalette {
    let keyword: NSColor
    let control: NSColor
    let type: NSColor
    let comment: NSColor
    let number: NSColor
    let string: NSColor
    let system: NSColor
    let directive: NSColor
    let fg: NSColor

    init(_ t: Theme) {
        keyword = NSColor(t.synKeyword)
        control = NSColor(t.synControl)
        type = NSColor(t.synType)
        comment = NSColor(t.synComment)
        number = NSColor(t.synNumber)
        string = NSColor(t.synString)
        system = NSColor(t.synSystem)
        directive = NSColor(t.synDirective)
        fg = NSColor(hex: t.editorFG)
    }

    func color(_ k: TokKind) -> NSColor? {
        switch k {
        case .keyword: return keyword
        case .control: return control
        case .type: return type
        case .comment: return comment
        case .number: return number
        case .string: return string
        case .system: return system
        case .directive, .attribute: return directive
        case .typeName: return type
        case .funcName: return system
        case .ident, .op, .placeholder: return nil
        }
    }
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
    static let uiFont = Font.system(size: 13)
    static let smallFont = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

/// The macOS 27 SDK declares `@State` as a macro whose plugin ships only with Xcode.
/// Referring to the property wrapper through an alias lets this build with Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
