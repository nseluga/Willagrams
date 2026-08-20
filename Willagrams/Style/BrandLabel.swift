import SwiftUI

/// The uppercase Fragment Mono metadata label the comp uses on every screen —
/// section kickers, counts, and the status line under a title.
///
/// It is a modifier rather than a view so it can dress a `Text` that already
/// carries accessibility traits, and so the caller keeps control of the string.
/// The uppercasing is deliberately *not* done here: `Text` has no case
/// transform that VoiceOver reads correctly, so callers pass the string they
/// mean and the font does the rest.
public struct BrandMonoLabel: ViewModifier {

    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(DesignTokens.Typography.monoLabel)
            .tracking(DesignTokens.Typography.monoLabelTracking)
            .foregroundStyle(DesignTokens.Palette.textSecondary)
    }
}

public extension View {
    /// Fragment Mono at label size, tracked out, in the secondary ink.
    func monoLabel() -> some View { modifier(BrandMonoLabel()) }
}

/// The same label in the accent ink, for a count that wants to be noticed —
/// the comp uses it for pending request counts and the live-rules kicker.
public struct BrandMonoAccentLabel: ViewModifier {

    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(DesignTokens.Typography.monoLabel)
            .tracking(DesignTokens.Typography.monoLabelTracking)
            .foregroundStyle(DesignTokens.Palette.accent)
    }
}

public extension View {
    func monoLabelAccent() -> some View { modifier(BrandMonoAccentLabel()) }
}
