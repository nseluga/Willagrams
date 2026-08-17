import WillagramsRules

/// The rules in force, as short lines both players can read.
///
/// Pure: same options in, same lines out, in the same order. It reads no store,
/// touches no catalogue, and loads no word list — resolving a dictionary id
/// costs a hash over ~170k words and can fail, neither of which belongs behind
/// a function that claims to be a pure description of what the host chose. The
/// caller already holds the resolved entry (``MatchOptionsForm/dictionaryName``)
/// and the game words (`Terminology`), so both arrive as parameters.
///
/// Only rules that *differ* from ``MatchOptions/standard`` earn a line — a
/// standard match reads as one line, the word list, and every extra line on
/// screen is something the host actually changed.
public enum RulesSummary {

    /// Lines describing `options`, in a fixed order: shortest word, then
    /// ``Terminology/swap``, then the word list. Built from an ordered array,
    /// so two calls with the same input give the same lines in the same order.
    ///
    /// - Parameters:
    ///   - options: what the host chose. Compared in its ``MatchOptions/validated``
    ///     form, so an out-of-range value does not read as a deliberate change.
    ///   - dictionaryName: the selected list's player-facing name.
    ///   - swapName: the game's word for the swap move — pass `Terminology.swap`.
    public static func lines(
        for options: MatchOptions,
        dictionaryName: String,
        swapName: String
    ) -> [String] {
        let rules = options.validated
        let standard = MatchOptions.standard

        return [
            rules.minimumWordLength == standard.minimumWordLength
                ? nil
                : "Shortest word: \(rules.minimumWordLength) letters",
            rules.swapEnabled == standard.swapEnabled
                ? nil
                : "\(swapName): \(rules.swapEnabled ? "on" : "off")",
            "Word list: \(dictionaryName)",
        ].compactMap { $0 }
    }
}
