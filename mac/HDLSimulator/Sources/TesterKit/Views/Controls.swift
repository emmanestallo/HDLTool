import AppKit
import SwiftUI

// MARK: - Text fields

struct VSTextField: View {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    var invalid = false
    var onCommit: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.dimFG.opacity(0.8)))
            .textFieldStyle(.plain)
            .font(mono ? UI.mono : UI.uiFont)
            .foregroundStyle(theme.fg)
            .focused($focused)
            .onSubmit { onCommit?() }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 2).fill(theme.inputBG))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(invalid ? theme.error : (focused ? theme.focusBorder : theme.inputBorder), lineWidth: 1)
            )
    }
}

/// Edits a Double; keeps the user's text while it is being typed.
struct NumField: View {
    @Binding var value: Double
    var unit: String? = nil
    var minValue: Double? = nil
    var width: CGFloat? = nil
    @Environment(\.theme) private var theme
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    private var parsed: Double? { Double(text.trimmingCharacters(in: .whitespaces)) }
    private var invalid: Bool {
        guard let v = parsed else { return true }
        if let m = minValue, v < m { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(UI.mono)
                .foregroundStyle(theme.fg)
                .focused($focused)
                .multilineTextAlignment(.trailing)
            if let unit {
                Text(unit).font(UI.smallFont).foregroundStyle(theme.dimFG)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: 2).fill(theme.inputBG))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(invalid ? theme.error : (focused ? theme.focusBorder : theme.inputBorder), lineWidth: 1)
        )
        .onAppear { text = Fmt.num(value) }
        .onChange(of: value) { _, v in
            if parsed != v { text = Fmt.num(v) }
        }
        .onChange(of: text) { _, _ in
            if let v = parsed, !invalid, v != value { value = v }
        }
        .onChange(of: focused) { _, f in
            if !f { text = Fmt.num(value) }
        }
    }
}

/// Text field for a Verilog value; shows red when the value cannot be read.
struct ValueField: View {
    @Binding var text: String
    var placeholder = "0"
    var allowEmpty = false
    var body: some View {
        VSTextField(text: $text, placeholder: placeholder, mono: true,
                    invalid: !(allowEmpty && text.isEmpty) && LogicLiteral.parse(text) == nil)
            .help("Examples: 0, 1, 42, -3, 8'hA5, 'b1010, 0x3F, 0b101, x, z")
    }
}

// MARK: - Buttons

struct VSButton: View {
    let title: String
    var icon: String? = nil
    var secondary = false
    var fill = true
    let action: () -> Void
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12)) }
                Text(title).font(UI.uiFont)
            }
            .foregroundStyle(secondary ? theme.secondaryButtonFG : theme.buttonFG)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(secondary ? theme.secondaryButtonBG : theme.buttonBG)
                    .brightness(hovering ? (theme.isDark ? 0.06 : -0.04) : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var color: Color? = nil
    var size: CGFloat = 13
    var disabled = false
    let action: () -> Void
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle((color ?? theme.titleFG).opacity(disabled ? 0.35 : 1))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering && !disabled ? theme.listHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct LinkButtonStyle: ButtonStyle {
    let color: Color
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UI.uiFont)
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.7 : 1))
            .underline(hovering)
            .onHover { hovering = $0 }
    }
}

/// VS Code's checkbox.
struct VSCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? theme.buttonBG : theme.inputBG)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isOn ? theme.buttonBG : theme.inputBorder, lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.buttonFG)
                    }
                }
                .frame(width: 16, height: 16)
                Text(title).font(UI.uiFont).foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row of mutually exclusive text buttons.
struct Segmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(.system(size: 12))
                        .foregroundStyle(on ? theme.buttonFG : theme.fg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(on ? theme.buttonBG : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 2).fill(theme.inputBG))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.inputBorder, lineWidth: 1))
    }
}

// MARK: - Layout pieces

struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOpen: Bool
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
            Text(title).font(.system(size: 11, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.dimFG).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering || isOpen { trailing() }
        }
        .foregroundStyle(theme.sidebarFG)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { isOpen.toggle() }
        .onHover { hovering = $0 }
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, isOpen: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOpen = isOpen
        self.trailing = { EmptyView() }
    }
}

/// Label on the left, control on the right — like VS Code's settings editor.
struct PropRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 92
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.dimFG)
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ResizeDivider: View {
    enum Axis { case vertical, horizontal }
    var axis: Axis = .vertical
    let color: Color
    let onDrag: (CGFloat) -> Void
    @ViewState private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay(
                Color.clear
                    .frame(width: axis == .vertical ? 7 : nil, height: axis == .horizontal ? 7 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        let c: NSCursor = axis == .vertical ? .resizeLeftRight : .resizeUpDown
                        if inside { c.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let t = axis == .vertical ? v.translation.width : v.translation.height
                                onDrag(t - last)
                                last = t
                            }
                            .onEnded { _ in last = 0 }
                    )
            )
            .zIndex(10)
    }
}

// MARK: - Stimulus icon

/// Icon for a stimulus kind. The clock is drawn as a square wave.
struct StimIcon: View {
    let kind: StimKind
    var size: CGFloat = 11
    var color: Color

    var body: some View {
        if kind == .clock {
            SquareWave()
                .stroke(color, style: StrokeStyle(lineWidth: max(1.2, size / 8), lineCap: .square, lineJoin: .miter))
                .frame(width: size * 1.25, height: size * 0.8)
        } else {
            Image(systemName: kind.icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

struct SquareWave: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width / 4
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + w, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + w, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + 2 * w, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + 2 * w, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 3 * w, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 3 * w, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// The small rounded label next to an input pin.
struct StimChip: View {
    let stim: Stimulus
    var selected = false
    var invalid = false
    @Environment(\.theme) private var theme

    static func width(_ s: Stimulus) -> CGFloat {
        CGFloat(min(s.summary.count, 12)) * Metrics.chipCharW + 30
    }

    var body: some View {
        let c = invalid ? theme.error : theme.stimColor(stim.kind)
        HStack(spacing: 4) {
            StimIcon(kind: stim.kind, size: 9, color: c)
                .frame(width: 12)
            Text(stim.summary.count > 12 ? String(stim.summary.prefix(11)) + "…" : stim.summary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 9).fill(c.opacity(selected ? 0.32 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? theme.focusBorder : c.opacity(0.55), lineWidth: selected ? 1.5 : 1))
    }
}

enum Metrics {
    static let monoCharW: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: f]).width
    }()
    static let chipCharW: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: f]).width
    }()
}
