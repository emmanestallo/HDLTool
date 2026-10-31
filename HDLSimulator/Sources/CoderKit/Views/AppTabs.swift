import HDLShell
import SwiftUI

/// The Coder / Tester tabs at the left of the title bar (⌘1 / ⌘2).
struct AppTabSwitcher: View {
    @Environment(\.theme) private var theme
    @ViewState private var hovering: AppTab?

    var body: some View {
        let shell = Shell.shared
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let on = shell.tab == tab
                Button { shell.show(tab) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon).font(.system(size: 10.5, weight: .semibold))
                        Text(tab.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? theme.titleFG : theme.titleFG.opacity(0.6))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(on ? (theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.07))
                                  : (hovering == tab ? theme.listHover : .clear))
                    )
                    .overlay(alignment: .bottom) {
                        if on { Capsule().fill(theme.accent).frame(height: 2).padding(.horizontal, 8).offset(y: 1) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 ? tab : (hovering == tab ? nil : hovering) }
                .help("HDL \(tab.title) (\(tab.shortcut))")
            }
        }
    }
}
