import CoreGraphics
// One module in the app; `BoardKit` in `Tests/ShellTests` (see `MatchBoard.swift`).
#if canImport(BoardKit)
import BoardKit
#endif

/// The pool bag's sizing decision, and the count's text formatting, pulled
/// out of `MatchHUD` and `MatchHUDModel` so both are testable without a
/// simulator — the same reason `MenuLayout` is a plain struct.
///
/// No SwiftUI import: `ShellTests` builds for macOS, and only a
/// SwiftUI-free type compiles into that target (see `MenuLayout.swift`).
public struct MatchHUDLayout: Equatable {

    /// The bag at regular height — an iPad, or a phone held portrait. The
    /// only readout on the board, alone in its corner, so it can afford the
    /// room.
    public static let regularBagSize: CGFloat = 96

    /// The bag on a landscape phone, where compact height leaves far less
    /// room above the controls. Still legible, just smaller than the iPad.
    public static let compactBagSize: CGFloat = 72

    /// True on a landscape phone — mirrors `verticalSizeClass == .compact`.
    public let isCompact: Bool

    /// The bag's edge, in points.
    public let bagSize: CGFloat

    public init(isCompact: Bool) {
        self.isCompact = isCompact
        bagSize = isCompact ? Self.compactBagSize : Self.regularBagSize
    }

    /// `MatchHUD`'s edge padding. Kept in sync by hand with
    /// `DesignTokens.Space.m`, which this SwiftUI-free file cannot import —
    /// the same arrangement as `MenuLayout`.
    public static let edgePadding: CGFloat = 16

    /// Height reserved for the Draw / Swap / Resign row along the bottom edge.
    /// Matches `MenuLayout`'s compact / regular button heights.
    public static let compactControlRowHeight: CGFloat = 44
    public static let regularControlRowHeight: CGFloat = 52

    /// The HUD's footprint over the board, so recenter frames tiles clear of
    /// it. The control row always takes the bottom edge. The bag takes the
    /// leading edge on a landscape phone, where height is what is short, and
    /// the top edge otherwise, where width is.
    public var boardInsets: BoardInsets {
        let bag = Self.edgePadding + bagSize
        let row = Self.edgePadding + (isCompact ? Self.compactControlRowHeight : Self.regularControlRowHeight)
        return isCompact
            ? BoardInsets(leading: bag, bottom: row)
            : BoardInsets(top: bag, bottom: row)
    }

    /// The em dash standing in for a number that is not a game concept —
    /// `MatchHUDModel.unknownValue` delegates here so the literal lives in
    /// one place.
    public static let unknownValue = "—"

    /// The count's display text: the plain number when the session knows
    /// one, `unknownValue` when it does not. Never a guess.
    public static func poolValue(_ remaining: Int?) -> String {
        guard let remaining else { return unknownValue }
        return String(remaining)
    }
}
