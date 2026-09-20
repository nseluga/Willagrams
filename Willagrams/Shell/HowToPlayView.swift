//
//  HowToPlayView.swift
//  Willagrams
//
//  The rules screen. Every word on it lives in `HowToPlay`, the page state
//  lives in `HowToPlayPager`, and this file draws them and decides nothing.
//
//  It reads no match state, because there is none to read: the route that leads
//  here carries nothing and is only reachable from the menu.
//
//  A pager, one rule per page — comp screen 06 — rather than the old grid: the
//  portrait phone has no room for six cards at once.
//

import SwiftUI

struct HowToPlayView: View {

    let shell: ShellModel

    @State private var pager = HowToPlayPager(count: HowToPlay.rules.count)

    var body: some View {
        let rule = HowToPlay.rules[pager.index]

        VStack(spacing: DesignTokens.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Button(HowToPlay.backLabel) { shell.returnToMenu() }
                    .buttonStyle(.brandText)
                Spacer(minLength: DesignTokens.Space.m)
                Text(pager.pageLabel).monoLabel()
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                Text(Self.number(pager.page))
                    .font(DesignTokens.Typography.button)
                    .foregroundStyle(DesignTokens.Palette.onAccent)
                    .frame(width: Self.numberTileSide, height: Self.numberTileSide)
                    .background(DesignTokens.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous))

                Text(rule.title)
                    .font(DesignTokens.Typography.display)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)

                Text(rule.body)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: DesignTokens.Space.s) {
                ForEach(0..<HowToPlay.rules.count, id: \.self) { dot in
                    Circle()
                        .fill(dot == pager.index ? DesignTokens.Palette.accent : DesignTokens.Palette.hairline)
                        .frame(width: Self.dotSide, height: Self.dotSide)
                }
            }

            HStack(spacing: DesignTokens.Space.m) {
                Button(HowToPlay.backLabel) { pager.back() }
                    .buttonStyle(.brandQuiet)
                Button(pager.primaryLabel) {
                    if pager.isLastPage {
                        shell.returnToMenu()
                    } else {
                        pager.next()
                    }
                }
                .buttonStyle(.brandPrimary)
            }
        }
        .screenPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// Zero-padded so the number tile sits on one optical width across pages.
    private static func number(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static let numberTileSide: CGFloat = 54
    private static let dotSide: CGFloat = 7
}
