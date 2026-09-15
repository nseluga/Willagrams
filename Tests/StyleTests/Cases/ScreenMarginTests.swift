import Foundation
import SwiftUI
import Testing
import StyleKit

/// `ScreenMargin.value` executed against the real tokens. Expectations are
/// written-out literals, never the tokens, so a changed token value fails here.
@Suite("Screen margin")
struct ScreenMarginTests {

    /// Every (horizontal, vertical) pair, nil included. Nil means "not compact".
    static let cases: [(UserInterfaceSizeClass?, UserInterfaceSizeClass?, CGFloat)] = [
        (.compact, .regular, 16),   // portrait phone
        (.compact, nil, 16),
        (.compact, .compact, 12),   // smallest landscape phone
        (.regular, .compact, 12),   // large landscape phone
        (nil, .compact, 12),
        (.regular, .regular, 40),   // iPad
        (.regular, nil, 40),
        (nil, .regular, 40),
        (nil, nil, 40),
    ]

    @Test("Each size-class pair, nil included, picks 12 / 16 / 40")
    func everyCombination() {
        for (h, v, want) in Self.cases {
            #expect(ScreenMargin.value(horizontal: h, vertical: v) == want, "h=\(String(describing: h)) v=\(String(describing: v))")
        }
    }

    @Test("Landscape phone < portrait phone < iPad")
    func ordering() {
        #expect(DesignTokens.Space.screenMarginCompact == 12)
        #expect(DesignTokens.Space.screenMarginPhone == 16)
        #expect(DesignTokens.Space.screenMargin == 40)
        #expect(DesignTokens.Space.screenMarginCompact < DesignTokens.Space.screenMarginPhone)
        #expect(DesignTokens.Space.screenMarginPhone < DesignTokens.Space.screenMargin)
    }

    @Test(".screenPadding() pads by ScreenMargin.value over both size classes")
    func screenPaddingCallsValue() throws {
        let source = StyleRepo.strippingComments(try StyleRepo.source("DesignTokens.swift"))
        guard let start = source.range(of: "struct ScreenPadding") else {
            Issue.record("ScreenPadding modifier not found"); return
        }
        let body = String(source[start.upperBound...])
        #expect(body.contains(#"@Environment(\.horizontalSizeClass)"#))
        #expect(body.contains(#"@Environment(\.verticalSizeClass)"#))
        #expect(body.contains("padding(ScreenMargin.value(horizontal: horizontalSizeClass, vertical: verticalSizeClass))"))
        #expect(source.contains("modifier(ScreenPadding())"))
    }
}
