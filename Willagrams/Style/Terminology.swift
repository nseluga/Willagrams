import Foundation

/// Every player-facing name for a game concept.
///
/// **This is the IP fence.** Bananagrams' vocabulary — bunch, split, peel,
/// dump, bananas, rotten — is trademarked and must never reach the screen.
/// Game mechanics are not copyrightable; the words for them are the exposure.
///
/// No view hardcodes one of these strings. `TerminologyFenceTests` fails the
/// build if a banned term appears anywhere under `Willagrams/`.
public enum Terminology {

    /// The shared face-down supply every player draws from.
    public static let pool = "Pool"

    /// Placing your last tile: every player takes one from the Pool.
    public static let draw = "Draw"

    /// Return one tile to the Pool, take three.
    public static let swap = "Swap"

    /// Called when a player has used every tile and the Pool is empty.
    public static let winCall = "Willagrams!"

    /// A board that blocks Draw — more than one cluster, or an unknown word.
    public static let invalid = "Invalid"

    /// Shown over the countdown before tiles are dealt.
    public static let countdownTitle = "Get ready"
}
