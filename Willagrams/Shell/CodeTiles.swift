//
//  CodeTiles.swift
//  Willagrams
//
//  The six boxes that show a play code — the host's invite code, or the
//  characters a guest has typed so far. Plain and SwiftUI-free, so
//  `TwoPlayerView` and its tests read the same six-element answer rather than
//  a view branching on `HostLobbyModel`/`JoinModel` twice.
//
//  Must stay listed in the `Shell` target's `exclude:` in
//  `Tests/ShellTests/Package.swift` only if it ever grows a SwiftUI import —
//  today it has none, so it needs no entry there.
//

/// Which end of the code this tile row is for.
public enum CodeTileMode: Equatable, Sendable {
    case host
    case join
}

/// One of the six boxes: a character already in hand, or a slot nobody has
/// filled yet.
public enum CodeTile: Equatable, Sendable {
    /// A character from the code, host or guest. `accent` is set on exactly
    /// one tile — the host's last — which is the one the design calls out as
    /// the code's own color rather than a plain tile face.
    case filled(Character, accent: Bool)
    /// An untyped slot, drawn dashed.
    case empty

    /// How many tiles a code row shows. `OnlineMatch` mints invite codes at
    /// this length and `JoinModel.codeLength` names the same number for the
    /// field beside it; this is the tile row's own copy of it so the row can
    /// be built before either model exists.
    public static let length = 6

    /// The six tiles for `code` under `mode`.
    ///
    /// Host reads six filled tiles once a code exists, the last accented —
    /// `code` is always exactly ``length`` characters by the time a host has
    /// one. Join reads however much has been typed, dashed past that point,
    /// with no accent at all.
    public static func tiles(mode: CodeTileMode, code: String) -> [CodeTile] {
        let characters = Array(code)
        return (0..<length).map { index in
            guard index < characters.count else { return .empty }
            return .filled(characters[index], accent: mode == .host && index == length - 1)
        }
    }
}
