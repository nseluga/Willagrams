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
            title: "Build your board",
            body: """
                You start with a hand of tiles. Drag one to move it. Drop it \
                beside another to build a word. Double tap to move a group. \
                Only you see your board.
                """
        ),
        Rule(
            title: "One connected group",
            body: """
                Every tile you hold must sit in one connected group. Every run \
                of two or more tiles must read as a real word across and down. \
                A run that is not a word flashes \(Terminology.invalid).
                """
        ),
        Rule(
            title: Terminology.draw,
            body: """
                \(Terminology.draw) is unlocked once your board is finished. It \
                takes one tile from the \(Terminology.pool) for every player, so \
                your opponent pays too. Your new tile usually breaks the grid \
                you just built. Rebuild and \(Terminology.draw) again.
                """
        ),
        Rule(
            title: Terminology.pool,
            body: """
                The \(Terminology.pool) is the shared supply, counted on the bag \
                in the corner. Every tile came out of it. At zero there is \
                nothing left to take.
                """
        ),
        Rule(
            title: Terminology.swap,
            body: """
                Select a letter you cannot place. \(Terminology.swap) puts it \
                back and deals you three in its place. One bad letter costs you \
                two extra ones.
                """
        ),
        Rule(
            title: Terminology.winCall,
            body: """
                The \(Terminology.winCall) button appears only when it would \
                work: the \(Terminology.pool) is empty and every tile you hold \
                sits in one finished board. Press it and you have won.
                """
        ),
    ]
}
