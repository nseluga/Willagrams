//
//  HowToPlay.swift
//  Willagrams
//
//  Every word the rules screen says, as values a test can read. `HowToPlayView`
//  renders these and decides nothing.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure copy, so
//  it compiles into the macOS `Shell` test target and must NOT be listed in that
//  target's `exclude:`. That is the point: the view is untestable, so the copy
//  lives here where `HowToPlayTests` can assert the IP fence over it directly.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Style` into the same module as the shell, where
// there is nothing to import. `Tests/ShellTests` compiles it as a separate one,
// so this import is real there and only there — the same shim `SoloMatch.swift`
// and `ResultsModel.swift` use.
#if canImport(Style)
import Style
#endif

/// The rules, in the app's own words.
///
/// A namespace of constants rather than an `@Observable` model: this screen has
/// no state, reads no match and outlives none — it is reachable from the menu
/// and goes back there. Every game concept comes from ``Terminology``, the
/// frozen IP fence; only screen chrome is spelled locally.
public enum HowToPlay {

    /// One block of the screen: a heading and the sentences under it.
    public struct Rule: Hashable, Sendable, Identifiable {
        public let title: String
        public let body: String

        public var id: String { title }

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Local chrome, not `Terminology`: that file names game concepts, not
    /// screens.
    public static let title = "How to Play"
    public static let backLabel = "Back"

    public static let rules: [Rule] = [
        Rule(
            title: Terminology.pool,
            body: """
                The \(Terminology.pool) is the shared face-down supply. \
                Every tile you play comes out of it.
                """
        ),
        Rule(
            title: Terminology.draw,
            body: """
                \(Terminology.draw) takes one more tile from the \
                \(Terminology.pool) for every player at once. You may only \
                \(Terminology.draw) when every tile you hold is on the board.
                """
        ),
        Rule(
            title: "One connected group",
            body: """
                Every tile on your board must join one connected group, reading \
                across and down as real words. While any word is \
                \(Terminology.invalid), or a tile stands apart from the rest, \
                \(Terminology.draw) stays locked.
                """
        ),
        Rule(
            title: Terminology.swap,
            body: """
                A letter you cannot use goes back: \(Terminology.swap) returns \
                one tile to the \(Terminology.pool) and gives you three in its \
                place.
                """
        ),
        Rule(
            title: Terminology.winCall,
            body: """
                When the \(Terminology.pool) is empty and you lay your last \
                tile into a valid board, \(Terminology.winCall) ends the match \
                and you have won.
                """
        ),
    ]
}
