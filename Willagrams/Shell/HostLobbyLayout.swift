import CoreGraphics

/// The Host Lobby's sizing decisions: the invite code's font size and the
/// action buttons' height, smaller under a compact vertical size class (a
/// landscape phone) than on an iPad.
///
/// A plain struct, not a View — no SwiftUI import — so `ShellTests` can
/// construct one directly and assert on its numbers without a simulator.
/// Mirrors `MenuLayout`'s shape: `HostLobbyView` reads
/// `@Environment(\.verticalSizeClass)` itself and hands this struct the
/// resulting `isCompact`, the same switch `ButtonStyles` reads from the
/// environment directly.
public struct HostLobbyLayout: Equatable {

    /// The regular code font, unchanged from the screen's current fixed size.
    private static let regularCodeFontSize: CGFloat = 44
    /// Scaled down for a landscape phone, same ~0.73 ratio `buttonCompact`
    /// uses against `button` (15/20).
    private static let compactCodeFontSize: CGFloat = 32

    /// The regular button height, unchanged from the screen's current fixed
    /// value.
    private static let regularButtonHeight: CGFloat = 36
    private static let compactButtonHeight: CGFloat = 32

    public let isCompact: Bool
    public let codeFontSize: CGFloat
    public let buttonHeight: CGFloat

    public init(isCompact: Bool) {
        self.isCompact = isCompact
        codeFontSize = isCompact ? Self.compactCodeFontSize : Self.regularCodeFontSize
        buttonHeight = isCompact ? Self.compactButtonHeight : Self.regularButtonHeight
    }
}
