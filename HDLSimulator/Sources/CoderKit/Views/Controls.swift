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

