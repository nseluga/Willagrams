import Foundation

/// SplitMix64. Deterministic across platforms and OS versions, unlike the
/// system generator — a seed has to mean the same shuffle on both devices for
/// a match to be reproducible or a bug to be replayable.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How many of each letter are in a full pool.
///
/// Tuned for this game from English letter frequency with a floor of two on
/// the rare letters, not copied from any existing set. Letter counts are
/// functional rather than expressive, but there is no reason to ship numbers
/// that invite the comparison.
public enum LetterDistribution {
    public static let standard: [Character: Int] = [
        "E": 17, "A": 13, "I": 11, "O": 10, "T": 9, "N": 9,
        "R": 8, "S": 7, "D": 6, "U": 6, "L": 5,
        "H": 4, "G": 4, "C": 4, "M": 4,
        "P": 3, "B": 3, "Y": 3, "F": 3, "W": 3,
        "V": 2, "K": 2, "J": 2, "X": 2, "Q": 2, "Z": 2,
    ]

    /// 144.
    public static var totalTiles: Int {
        standard.values.reduce(0, +)
    }
}

/// The shared face-down supply. Player-facing name: the Pool.
///
/// The host owns the only real instance and broadcasts what it hands out;
/// clients never draw from a local copy.
public struct Pool: Codable, Sendable, Equatable {
    public private(set) var tiles: [Tile]

    public var count: Int { tiles.count }
    public var isEmpty: Bool { tiles.isEmpty }

    public init(tiles: [Tile]) {
        self.tiles = tiles
    }

    /// A full 144-tile pool, shuffled reproducibly from `seed`.
    ///
    /// Letters are deterministic; tile ids are not, since they are generated
    /// fresh and travel over the wire with every grant.
    public static func standard(seed: UInt64) -> Pool {
        var generator = SeededGenerator(seed: seed)
        var letters: [Character] = []
        // Sorted so the pre-shuffle order does not depend on dictionary order.
        for (letter, count) in LetterDistribution.standard.sorted(by: { $0.key < $1.key }) {
            letters.append(contentsOf: repeatElement(letter, count: count))
        }
        letters.shuffle(using: &generator)
        return Pool(tiles: letters.map { Tile(letter: $0) })
    }

    /// Takes `n` tiles.
    /// - Returns: nil if fewer than `n` remain, leaving the pool untouched.
    public mutating func draw(_ n: Int) -> [Tile]? {
        guard n >= 0, tiles.count >= n else { return nil }
        let drawn = Array(tiles.suffix(n))
        tiles.removeLast(n)
        return drawn
    }

    /// How many tiles a swap hands back for the one it takes. Named here
    /// because the HUD has to grey the control out on the same number the
    /// pool refuses on, and two copies of a `3` drift.
    public static let swapSize = 3

    /// Returns one tile to the pool and takes three.
    ///
    /// The three are drawn *before* the returned tile goes back, so a swap can
    /// never hand you the tile you just gave up.
    /// - Returns: nil if fewer than 3 remain, leaving the pool untouched.
    public mutating func swap(_ tile: Tile, using generator: inout SeededGenerator) -> [Tile]? {
        guard let drawn = draw(Self.swapSize) else { return nil }
        tiles.insert(tile, at: tiles.isEmpty ? 0 : Int.random(in: 0...tiles.count, using: &generator))
        return drawn
    }
}
