import SwiftUI

/// The app root: a `switch` over ``ShellModel/route`` and nothing else.
///
/// No navigation container of any kind — a guardrail test enforces that by
/// name. The screens are full-bleed modes rather than a drill-down hierarchy,
/// so a nav bar would be hidden on every one of them, and a navigation path
/// lives inside a View where no test in this repo can reach it.
/// This view holds no navigation state and makes no routing decision — it
/// renders whatever route `ShellModel` reports.
///
/// The four cases are placeholders. Later items replace each with its real
/// screen; nothing else about this file changes when they do.
struct ShellRootView: View {

    let shell: ShellModel

    var body: some View {
        Group {
            switch shell.route {
            case .menu: placeholder(Self.menuLabel)
            case .countdown: placeholder(Terminology.countdownTitle)
            case .match: placeholder(Self.matchLabel)
            case .results: placeholder(Self.resultsLabel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Palette.canvasTop)
    }

    private func placeholder(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.Typography.title)
            .foregroundStyle(DesignTokens.Palette.textPrimary)
            .padding(DesignTokens.Space.l)
    }

    /// Not `Terminology` constants: that file is the frozen IP fence and names
    /// game concepts, not screens. Placeholder copy, replaced with the real
    /// screens; named here so there is exactly one copy of each.
    private static let menuLabel = "Willagrams"
    private static let matchLabel = "Match"
    private static let resultsLabel = "Results"
}
