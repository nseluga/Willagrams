import WillagramsRules

/// A named set of match rules the host can pick before opening a match.
///
/// The name is what the player sees; the options are what travels on `.start`.
public struct Ruleset: Equatable, Sendable {
    public var name: String
    public var options: MatchOptions

    public init(name: String, options: MatchOptions) {
        self.name = name
        self.options = options
    }

    /// Every preset the host can choose from.
    ///
    /// One entry today, deliberately: "Standard" is exactly today's shipped
    /// behavior, so a player who never opens settings gets the same match they
    /// always got. Further presets are added here, not synthesized.
    public static let catalogue = [standard]

    public static let standard = Ruleset(name: "Standard", options: .standard)
}
