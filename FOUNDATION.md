# Willagrams — Foundation

These are the contracts every lane builds against; they land on `main` before
any lane forks. Shapes below are frozen — a lane that needs one changed files an
amendment, it does not edit around it.

Decisions this file encodes:

- **SwiftUI, iOS only, no backend.** GameKit `GKMatch` carries friend-to-friend
  play; there is no server, no auth, no database.
- **Tiles live on an integer lattice** (`Coord`, signed, unbounded). The board
  view drags freely and snaps on release, so it feels like nudging tiles on a
  table; the lattice underneath is what makes word extraction exact.
- **Loose tiles are legal.** Each connected group is a cluster. A player may
  Draw only with exactly one cluster and zero invalid words.
- **Terminology is the IP fence:** Pool, Draw, Swap, `Willagrams!`, Invalid.
  The Bananagrams vocabulary — Bunch, Split, Peel, Dump, Bananas, Rotten — must
  never appear in player-facing copy.
- **ENABLE** is the word list: public domain, no proper nouns. The Scrabble
  tournament lists (TWL, SOWPODS) are Hasbro/Merriam property and are not
  shippable.

Rules engine lives in a local SwiftPM package so `swift test` runs it in seconds
with no simulator. The app target uses Xcode synchronized folder groups, so
lanes add files without touching `project.pbxproj`.

---

- task: Scaffold the Xcode app project and the WillagramsRules SwiftPM package, and delete the JS stub
  done when:
    - `game.js`, `index.html`, `test.js`, `package.json` are gone from the repo
    - `swift build` and `swift test` succeed against `Package.swift` defining a `WillagramsRules` library target at `Sources/WillagramsRules/` and a test target at `Tests/WillagramsRulesTests/`
    - `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` succeeds, with the app target consuming the local `WillagramsRules` package
    - `Willagrams/Willagrams.entitlements` declares `com.apple.developer.game-center`, and `Willagrams/Board/`, `Match/`, `Shell/`, `App/`, `Style/` exist as synchronized folder groups so adding a file does not modify `project.pbxproj`
  risk: a malformed `project.pbxproj` fails to open in Xcode or silently drops a
        folder group, so a lane's new files never compile into the app — loud at
        build time, but it blocks every lane until fixed
  difficulty: open — hand-authoring a modern pbxproj with
        `PBXFileSystemSynchronizedRootGroup` rather than generating it; the
        simulator build is the only real proof
  status: done

- task: Define the core placement contracts in Contracts.swift
  done when:
    - `Sources/WillagramsRules/Contracts.swift` declares, public and `Sendable`: `struct Coord: Hashable, Codable { let row: Int; let col: Int }` (signed, unbounded); `struct Tile: Identifiable, Hashable, Codable { let id: UUID; let letter: Character }`; `struct Placement: Hashable, Codable { let tile: Tile; let coord: Coord; var tileID: UUID }`; `struct PlayerID: Hashable, Codable { let rawValue: String }`; `enum Direction: Codable { case across, down }`; `struct BoardWord: Hashable { let text: String; let origin: Coord; let direction: Direction }`; `enum PlacementError: Error, Equatable { case occupied(Coord); case tileNotInHand(UUID) }`
    - `struct Board: Codable, Sendable` exposes `private(set) var placements: [Coord: Tile]`, `mutating func place(_ tile: Tile, at coord: Coord) throws`, `mutating func remove(at coord: Coord) -> Tile?`, and `func tile(at coord: Coord) -> Tile?`
    - `Board.placementList: [Placement]` returns every placed tile sorted by (row, col), so two encodings of one board are byte-identical
    - `place` into an occupied coord throws `PlacementError.occupied(coord)` and leaves `placements` unchanged
    - A fixture encodes a 3-tile `Board` to JSON and decodes it back to an equal value, and asserts negative-coordinate placement round-trips
  risk: a field added or renamed here breaks board, match, and shell at once —
        loud at compile time, but every lane stalls
  difficulty: low — plain value types, synthesized Codable
  status: done
  parallel-group: a

- task: Add the WordList contract and ship the ENABLE dictionary with its license record
  done when:
    - `Sources/WillagramsRules/WordList.swift` declares `public protocol WordList: Sendable { func contains(_ word: String) -> Bool }`, matching case-insensitively over A–Z
    - `Sources/WillagramsRules/Resources/dictionary.txt` contains the ENABLE list, one lowercase word per line, and `docs/dictionary-license.md` records its source URL, public-domain status, and word count
    - A concrete `EnableWordList` loads the bundled resource and a fixture asserts `contains("cat") == true`, `contains("CAT") == true`, `contains("qqqq") == false`, and that no entry contains a non-letter character
    - Lookup of 1,000 random words completes in under 50ms after load, median of 5 runs
  risk: a truncated or proper-noun-laden list silently rejects valid words and
        accepts junk; players hit it mid-game and blame the app, not the data
  difficulty: low — download, normalize, load into a Set
  status: done
  parallel-group: a

- task: Pin the DesignTokens and Terminology key shapes
  done when:
    - `Willagrams/Style/DesignTokens.swift` declares `enum DesignTokens` with nested `Color` (`tileFace`, `tileEdge`, `tileLetter`, `boardSurface`, `accent`, `danger`, `textPrimary`, `textSecondary`), `Space` (`xs`, `s`, `m`, `l`, `xl`: CGFloat), `Radius` (`tile`, `panel`: CGFloat), `Typography` (`tileLetter`, `title`, `body`, `caption`: Font), and `Motion` (`snapDuration`, `dealDuration`: Double; `snapThreshold`: CGFloat)
    - `Willagrams/Style/Terminology.swift` declares `enum Terminology` with `pool = "Pool"`, `draw = "Draw"`, `swap = "Swap"`, `winCall = "Willagrams!"`, `invalid = "Invalid"`, `countdownTitle = "Get ready"`
    - A fixture asserts none of `bunch`, `split`, `peel`, `dump`, `banana`, `rotten` appears case-insensitively in any `Terminology` value
    - Placeholder token values compile and render; the style lane replaces the values, not the key names
  risk: a lane hardcoding a color or a player-facing word bypasses the fence —
        silent, and a trademarked term reaching the App Store is the expensive
        version of this failure
  difficulty: low — declarations plus placeholder values
  status: done
  parallel-group: a

- task: Implement Board cluster and word analysis with structured validation
  done when:
    - `Board.clusters` returns connected components over 4-adjacency as `[Set<Coord>]`, empty for an empty board and one entry for a fully connected board
    - `Board.words() -> [BoardWord]` returns every maximal horizontal and vertical run of length >= 2, each with its origin coord and direction; single isolated tiles produce no word
    - `Board.validate(against: WordList) -> BoardValidation` returns `struct BoardValidation: Equatable, Sendable { let clusterCount: Int; let invalidWords: [BoardWord]; let tileCount: Int; var isComplete: Bool { clusterCount == 1 && invalidWords.isEmpty && tileCount >= 2 } }`
    - A board holding exactly one tile reports `isComplete == false` — a lone tile spells nothing and must not open the Draw gate
    - A fixture builds a board spelling CAT across and COT down sharing the C, and asserts `clusterCount == 1`, `invalidWords.isEmpty`, and `words()` has exactly 2 entries; a second fixture with a detached tile asserts `clusterCount == 2` and `isComplete == false`
  risk: wrong word extraction lets an illegal board pass the Draw gate, or
        blocks a legal one — silent to the player, who just sees Draw refuse
        with no reason they can see
  difficulty: low — flood fill plus two directional scans, both well-trodden
  status: done
  parallel-group: b

- task: Define Pool, the letter distribution, and GameState
  done when:
    - `Pool` exposes `static func standard(seed: UInt64) -> Pool`, `private(set) var tiles: [Tile]`, `var count: Int`, `mutating func draw(_ n: Int) -> [Tile]?` returning nil when fewer than n remain, and `mutating func swap(_ tile: Tile, using generator: inout SeededGenerator) -> [Tile]?` returning 3 tiles and reinserting 1 at a reproducible position, nil when fewer than 3 remain
    - `LetterDistribution.standard: [Character: Int]` sums to exactly 144 tiles across A–Z, tuned independently rather than copied from Bananagrams
    - `struct GameState: Codable, Sendable` holds `var pool: Pool`, `var hand: [Tile]`, `var board: Board`, `var status: MatchStatus`, where `enum MatchStatus: Codable, Equatable { case countdown(secondsRemaining: Int); case playing; case finished(winner: PlayerID) }`
    - A fixture asserts two `Pool.standard(seed: 42)` instances draw identical tile sequences, that draining the pool makes `draw(1)` return nil, and that `swap` leaves `count` reduced by exactly 2
  risk: a non-deterministic pool desyncs the two clients and they play from
        different bags — silent until someone draws a tile the other already
        holds
  difficulty: low — seeded generator plus array operations
  status: done
  parallel-group: b

- task: Define the MatchMessage wire contract
  done when:
    - `enum WireFormat { static let current = 1 }`; a checked-in `Tests/WillagramsRulesTests/Fixtures/wire-v1.json` decodes into every case, so a renamed case or label fails at test time rather than in a shipped match
    - `enum MatchMessage: Codable, Sendable, Equatable` declares `start(version: Int, seed: UInt64, startingHandSize: Int, countdownSeconds: Int)`, `drawRequest(player: PlayerID)`, `grant(player: PlayerID, tiles: [Tile])`, `swapRequest(player: PlayerID, returning: Tile)`, `swapGrant(player: PlayerID, tiles: [Tile], returned: Tile)`, `poolExhausted`, `win(player: PlayerID, placements: [Placement])`, `resign(player: PlayerID)`, and `rejected(reason: RejectionReason)`
    - `enum RejectionReason: Codable, Sendable, Equatable` declares `poolEmpty`, `notEnoughTilesToSwap`, `notYourTurn`, `unknownPlayer`
    - A fixture round-trips every case through `JSONEncoder`/`JSONDecoder` and asserts equality, including `win` carrying 21 placements
    - An encoded `win` message with 144 placements stays under 16KB, GameKit's reliable-send payload ceiling
  risk: a case added or reordered after a lane ships breaks decode between two
        app versions — silent, and it surfaces as a match that just stops
  difficulty: low — synthesized Codable over enums with associated values
  status: done
  parallel-group: b
