import WillagramsRules

/// The half-length game: a pool with about half of every letter.
///
/// A proportional half, not the first 72 tiles of a shuffled full pool: a
/// random half could come out with two vowels in it. Each letter keeps half its
/// standard count. The letters with an odd count take turns rounding up and
/// down, in alphabetical order, so the total is exactly half and no letter is
/// more than one tile away from its true half.
public extension LetterDistribution {

    static let half: [Character: Int] = {
        var roundUp = true
        var counts: [Character: Int] = [:]
        for (letter, count) in standard.sorted(by: { $0.key < $1.key }) {
            counts[letter] = count / 2
            guard count % 2 == 1 else { continue }
            if roundUp { counts[letter] = count / 2 + 1 }
            roundUp.toggle()
        }
        return counts
    }()

    static var halfTotalTiles: Int { half.values.reduce(0, +) }
}

public extension Pool {

    /// The half pool for `seed`: built the way `Pool.standard(seed:)` builds
    /// the full one, so one seed always gives one shuffle.
    static func half(seed: UInt64) -> Pool {
        var generator = SeededGenerator(seed: seed)
        var letters: [Character] = []
        for (letter, count) in LetterDistribution.half.sorted(by: { $0.key < $1.key }) {
            letters.append(contentsOf: Array(repeating: letter, count: count))
        }
        letters.shuffle(using: &generator)
        return Pool(tiles: letters.map { Tile(letter: $0) })
    }
}
