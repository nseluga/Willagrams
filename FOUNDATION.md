# Willagrams — Foundation

These are the contracts every lane builds against; they land on `main` before
any lane forks. Shapes below are frozen — a lane that needs one changed files an
amendment, it does not edit around it.

Decisions this file encodes:

- **SwiftUI, iOS only.** Round 1 assumed GameKit `GKMatch` with no server.
  **Round 2 supersedes that:** no file ever imported GameKit, and the backend is
  Supabase — hosted Postgres, Sign in with Apple, and realtime channels carrying
  `MatchMessage`. See the round-2 amendments at the foot of this file.
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

## Amendment — wire v2 (landed)

Spec: `docs/amendment-wire-v2.md`. Supersedes the `WireFormat.current = 1`
shape in the item above; that item stays as written because it is history.

- task: Add MatchOptions and the canonical word-list hash
  done when:
    - `Sources/WillagramsRules/MatchOptions.swift` declares `struct MatchOptions: Codable, Sendable, Equatable` with `minimumWordLength`, `swapEnabled`, `dictionaryID`, `dictionaryHash`, plus `static let standard` equal to today's shipped behavior
    - `validated` clamps `minimumWordLength` into `lengthRange` (`2...15`) and filters `dictionaryID` to letters/digits/-/_ and `dictionaryHash` to hex digits, both capped at 64 characters — every field arrives from a peer
    - `canonicalWordListHash(_:)` lowercases, dedupes, sorts, newline-joins, and SHA256s, so it is order- and duplicate-independent but content-sensitive
    - `MatchOptions.standardDictionaryHash` is pinned as a literal and a test asserts it equals `EnableWordList().canonicalHash`, so changing the bundled list fails at test time rather than desyncing a shipped match
    - `MinimumLengthWordList` decorates any `WordList`, rejecting anything shorter than its minimum and deferring the rest
  risk: an unvalidated option off the wire reaches the pool or the validator; a
        silently changed dictionary desyncs two devices mid-match
  difficulty: low — a struct, a decorator, and a hash
  status: done

- task: Bump the wire to v2 and carry the options in start
  done when:
    - `WireFormat.current == 2`; `MatchMessage.start` carries `options: MatchOptions`; `RejectionReason` gains `swapDisabled`
    - `Tests/WillagramsRulesTests/Fixtures/wire-v2.json` replaces the v1 fixture and decodes into all 13 messages, asserted against hand-built literals rather than re-encoded through this build
    - `MatchCodec.decode` still refuses any start whose version is not current, driven through the real entry point
  risk: a case added or reordered after a lane ships breaks decode between two
        app versions — silent, surfacing as a match that just stops
  difficulty: low — synthesized Codable plus a fixture regeneration
  status: done

- task: Enforce the options in the session and the host pool
  done when:
    - `MatchSession.applyStart` validates the arriving options, and refuses the start outright when `dictionaryHash` differs from this device's — `optionsRefusal` says why and the match never opens
    - A minimum above the floor wraps `dictionary` in `MinimumLengthWordList` once, so it reaches every existing reader including `canDraw`
    - `HostPool` rejects a swap request with `.swapDisabled` when swap is off, and `MatchSession.swap` short-circuits before the round trip
    - Both swap refusals return the player's Draw credit — neither is counted as answering a draw
    - The 36 pre-amendment engine tests and the 100 MatchTests still pass
  risk: a device that adopts the host's dictionary id while holding different
        content disagrees about legal words for the whole match, and the symptom
        lands mid-play as a rejected word rather than as a setup error
  difficulty: medium — the refusal path and the credit accounting are both easy
        to get subtly wrong
  status: done

---

## Round 2 amendments — the shippable release

Round 1 froze a two-player, no-backend game. Round 2's `MAP.md` adds `online`,
`account`, `friends`, `audio` and `launch`, and reopens `match` for up to six
players. These six items are the contracts those lanes build against. They land
on `integration` — this repo keeps the map layer on the trunk that carries the
merged lanes, not on the round-1 `main`.

Decisions this round encodes, each stated here because a lane would otherwise
discover it:

- **Six players, not two, and the wire carries the roster.** The roster travels
  in `start`, sorted ascending by `PlayerID.rawValue`, and the host is
  `roster[0]` — computed identically on every device, so there is still no
  negotiation message. `MatchTransport` therefore needs **no signature change**:
  `grant`/`swapGrant` already name their player and every device filters on it,
  so a broadcast fans out correctly to N peers exactly as it did to one.
- **A hand is not secret.** Broadcast grants have always let the peer see the
  tiles you drew; with six players that is five observers rather than one. Kept
  as-is for v1 — targeted delivery would need a transport change and the tiles
  come from a shared pool anyway.
- **A departed peer no longer ends the match.** Round 1 froze the board whenever
  the one peer was absent. With six, the board freezes only while a peer is
  `.reconnecting`, a `.gone` peer is dropped from the roster, and the match ends
  when fewer than two players remain present.
- **Seeds are signed.** Postgres `bigint` is signed 64-bit, so the host draws
  seeds in `0...Int64.max` rather than the full `UInt64` range. Nothing depends
  on the high bit; this avoids a `numeric` column and a lossy round-trip.
- **The backend gets the same seam the transport got.** `BackendClient` is a
  protocol with a `#if DEBUG` fake, so `account` and `friends` build and test
  with no Supabase project, exactly as `match` built against `FakeTransport`.
  Those two lanes stop being sequenced behind `online`'s implementation.
- **Every profile is readable by any signed-in player.** Friend codes are looked
  up by strangers by design, and the stats are the "cool stats" the profile page
  exists to show. Deliberate, not an oversight.

- task: Pin the audio playback seam so shell can call sound before the audio lane lands
  done when:
    - `Willagrams/Audio/AudioPlayer.swift` declares `public enum SoundEffect: String, Sendable, CaseIterable` with exactly `tilePlace`, `tileRecall`, `draw`, `swap`, `invalid`, `countdownTick`, `win`, `loss`, `menuTap`
    - the same file declares `public enum HapticStrength: Sendable, Equatable { case light, medium, heavy }` and `public protocol AudioPlayer: Sendable { var isMuted: Bool { get }; func play(_ effect: SoundEffect); func impact(_ strength: HapticStrength); func setMuted(_ muted: Bool) }`
    - `play` and `impact` are non-throwing, non-async and return `Void` — a caller on the main actor must never await a sound, and a missing asset is never an error the UI handles
    - `public struct SilentAudioPlayer: AudioPlayer` ships in Release, not behind `#if DEBUG`: it is the value every screen holds until the `audio` lane replaces it, and `isMuted` reports the value last set
    - `Tests/AudioTests/` exists as its own SwiftPM package and a fixture asserts `SoundEffect.allCases.count == 9`, that every `rawValue` is unique, and that `SilentAudioPlayer` round-trips `setMuted(true)` into `isMuted`
  guardrails:
    - `Willagrams/Audio/AudioPlayer.swift` is `protected:` after this item — `audio` adds concrete players beside it, it does not edit it
    - no `AVFoundation` or `CoreHaptics` import in this file; the seam stays platform-free so the engine-speed test package can compile it
  risk: a seam that returns `async` or `throws` forces every call site into a
        Task or a do/catch for a sound effect, and the whole app inherits it —
        loud only after every lane has already written its call sites
  difficulty: low — one enum, one protocol, one no-op struct
  status: done
  parallel-group: r2a

- task: Design the Supabase schema as migrations, with RLS on every table
  done when:
    - `supabase/migrations/0001_init.sql` creates exactly four tables in `public`: `profiles`, `friendships`, `matches`, `match_players`
    - `profiles` — `id uuid primary key references auth.users(id) on delete cascade`, `display_name text not null check (char_length(display_name) between 1 and 24)`, `friend_code text not null unique check (friend_code ~ '^[A-Z0-9]{8}$')`, `created_at timestamptz not null default now()`, `matches_played integer not null default 0`, `matches_won integer not null default 0`, `tiles_placed integer not null default 0`, `fastest_win_seconds integer null`, plus `check (matches_won <= matches_played)` and `check (fastest_win_seconds is null or fastest_win_seconds > 0)`
    - `friendships` — `requester_id uuid not null references public.profiles(id) on delete cascade`, `addressee_id uuid not null references public.profiles(id) on delete cascade`, `status text not null check (status in ('pending','accepted','blocked'))`, `created_at timestamptz not null default now()`, `responded_at timestamptz null`, `primary key (requester_id, addressee_id)`, `check (requester_id <> addressee_id)`, and `check ((status = 'pending') = (responded_at is null))`
    - a unique index `friendships_pair_idx on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id))` makes at most one row exist per unordered pair, so A→B and B→A cannot both be stored
    - `matches` — `id uuid primary key default gen_random_uuid()`, `host_id uuid not null references public.profiles(id) on delete cascade`, `invite_code text not null unique check (invite_code ~ '^[A-Z0-9]{6}$')`, `wire_version integer not null`, `seed bigint not null check (seed >= 0)`, `options jsonb not null`, `status text not null check (status in ('lobby','playing','finished','abandoned'))`, `created_at timestamptz not null default now()`, `started_at timestamptz null`, `finished_at timestamptz null`, `winner_id uuid null references public.profiles(id) on delete set null`, plus `check ((status in ('playing','finished')) = (started_at is not null))` and `check (winner_id is null or status = 'finished')`
    - `match_players` — `match_id uuid not null references public.matches(id) on delete cascade`, `player_id uuid not null references public.profiles(id) on delete cascade`, `joined_at timestamptz not null default now()`, `primary key (match_id, player_id)`
    - `alter table ... enable row level security` on all four, and every table has at least one policy: `profiles` selectable by any authenticated role, insertable and updatable only where `auth.uid() = id`; `friendships` selectable, insertable and updatable only where `auth.uid() in (requester_id, addressee_id)`; `matches` selectable by its host or any row in `match_players`, insertable only where `auth.uid() = host_id`; `match_players` selectable by any member of the same match, insertable only where `auth.uid() = player_id`
    - `supabase db lint` reports no errors, and `docs/schema.md` records each table's purpose, the invariants above in prose, and the two invariants **not** enforced in SQL — that a `playing` match holds 2 to 6 `match_players` rows, and that `winner_id` names one of them
  guardrails:
    - `supabase/migrations/**` is already `protected:` — `online` writes later migrations only through a fresh `/foundation` amendment
    - no seed data, no service-role key, and no `security definer` function in this migration
  risk: a table without RLS is world-readable and world-writable to anyone
        holding the anon key, which ships inside the app binary — silent, and
        the failure mode is a stranger editing another player's stats
  difficulty: medium — the RLS policies are the real work; the columns are
        mechanical
  status: done
  parallel-group: r2a

- task: Mirror the schema as Swift row types behind a BackendClient seam with a fake
  done when:
    - `Willagrams/Online/BackendContracts.swift` declares, public and `Sendable`: `struct Profile: Codable, Equatable, Identifiable` (`id: UUID`, `displayName: String`, `friendCode: String`, `createdAt: Date`, `matchesPlayed: Int`, `matchesWon: Int`, `tilesPlaced: Int`, `fastestWinSeconds: Int?`); `enum FriendshipStatus: String, Codable { case pending, accepted, blocked }`; `struct Friendship: Codable, Equatable` (`requesterID: UUID`, `addresseeID: UUID`, `status: FriendshipStatus`, `createdAt: Date`, `respondedAt: Date?`); `enum MatchRecordStatus: String, Codable { case lobby, playing, finished, abandoned }`; `struct MatchRecord: Codable, Equatable, Identifiable` (`id: UUID`, `hostID: UUID`, `inviteCode: String`, `wireVersion: Int`, `seed: Int64`, `options: MatchOptions`, `status: MatchRecordStatus`, `createdAt: Date`, `startedAt: Date?`, `finishedAt: Date?`, `winnerID: UUID?`); `struct MatchPlayerRow: Codable, Equatable` (`matchID: UUID`, `playerID: UUID`, `joinedAt: Date`)
    - every one of those types declares explicit `CodingKeys` mapping each property to its snake_case column name, so a column rename fails at test time rather than decoding to nil
    - `public enum BackendError: Error, Sendable, Equatable` declares `notAuthenticated`, `notFound`, `alreadyExists`, `blocked`, `matchFull`, `permissionDenied`, `offline`
    - `public protocol BackendClient: Sendable` declares `var currentUserID: UUID? { get async }`, `func signInWithApple(idToken: String, nonce: String) async throws -> Profile`, `func signOut() async throws`, `func profile(id: UUID) async throws -> Profile`, `func profile(friendCode: String) async throws -> Profile?`, `func updateDisplayName(_ name: String) async throws -> Profile`, `func friendships() async throws -> [Friendship]`, `func requestFriend(addresseeID: UUID) async throws -> Friendship`, `func respondToFriendRequest(requesterID: UUID, accept: Bool) async throws -> Friendship`, `func block(_ playerID: UUID) async throws -> Friendship`, `func createMatch(options: MatchOptions, seed: Int64) async throws -> MatchRecord`, `func joinMatch(inviteCode: String) async throws -> MatchRecord`, `func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow]`, `func transport(for match: MatchRecord, as player: PlayerID) async throws -> any MatchTransport`
    - `Willagrams/Online/FakeBackend.swift`, behind `#if DEBUG`, is an in-memory `actor` conforming to the whole protocol: it signs a fixed user in, stores profiles and friendships in dictionaries, enforces `matchFull` above six players and `alreadyExists` on a duplicate friend request, and returns a `FakeTransport` from `transport(for:as:)`
    - `Tests/OnlineTests/` exists as its own SwiftPM package, and fixtures assert that a JSON object using the real snake_case column names decodes into each of the five row types with every field populated, that `fastestWinSeconds`, `respondedAt`, `startedAt`, `finishedAt` and `winnerID` decode as nil when the column is null, and that a full `FakeBackend` run — sign in, request a friend, accept it, create a match, join it — completes with no error
  guardrails:
    - `Willagrams/Online/BackendContracts.swift` is `protected:` after this item; `FakeBackend.swift` is not, so `online` may deepen the fake
    - neither file imports `Supabase` — the seam stays free of the SDK so `account`, `friends` and their test packages compile without it
    - `PlayerID` still carries the backend user id as a string; `MatchRecord` and `Profile` use `UUID` because that is the column type, and the conversion happens at the seam
  risk: row types that disagree with the columns decode to nil rather than
        throwing, so a wrong `CodingKeys` shows up as an empty profile page
        rather than as an error anyone can trace
  difficulty: medium — the types are mechanical, the fake is the work
  status: done

- task: Bump the wire to v3 and carry the roster in start
  done when:
    - `Sources/WillagramsRules/MatchMessage.swift` declares `public enum MatchLimits { public static let players = 2...6 }` and `WireFormat.current == 3`
    - `MatchMessage.start` carries `roster: [PlayerID]` as its last label, alongside the existing `version`, `seed`, `startingHandSize`, `countdownSeconds` and `options`; no other case changes shape
    - `MatchMessage.validatedStart` (new) returns nil unless the roster is sorted ascending by `rawValue`, holds no duplicate, has `MatchLimits.players.contains(roster.count)`, and satisfies `startingHandSize <= MatchLimits.poolSize / roster.count` (**written as a division, not the multiplication this line first pinned: `startingHandSize * roster.count` traps on overflow for a hand size near `Int.max`, which is exactly what a modified peer sends**) — every field arrives from a peer, so this is the same clamp-at-the-boundary rule `MatchOptions.validated` follows
    - `Tests/WillagramsRulesTests/Fixtures/wire-v3.json` replaces the v2 fixture and decodes into every case, asserted against hand-built literals rather than re-encoded through this build
    - `PlayerID` in `Contracts.swift` no longer documents itself as "keyed by `GKPlayer.gamePlayerID`" — it is the backend user id as a string. Doc-comment only; the type does not change
    - the `MatchMessageTests` size assertion still holds and its comment names the 16KB ceiling as a transport budget rather than as GameKit's limit
    - a fixture asserts `validatedStart` rejects each of: an unsorted roster, a roster holding a duplicate, a roster of 1, a roster of 7, and `startingHandSize: 21` with a roster of 7
  guardrails:
    - `Sources/WillagramsRules/**` is `protected:`; this item is the amendment that opens it
    - the roster is the only addition — do not add a `players.count` field beside it, because two sources for one number is exactly what desyncs
  risk: a roster that is unsorted or holds a duplicate makes two devices
        disagree about who the host is, so both run a pool or neither does —
        silent, and it surfaces as a match that never deals
  difficulty: low — one label, one validator, one fixture regeneration
  status: done

- task: Generalize HostPool from a player pair to a roster
  done when:
    - `HostPool.init` takes `players: [PlayerID]` instead of a 2-tuple, and preconditions that the count is in `MatchLimits.players` and that `Set(players).count == players.count`
    - `HostPool.host(of players: [PlayerID]) -> PlayerID` replaces `host(of:_:)` and returns the lowest `rawValue`, so it agrees with `roster[0]` on every device; the two-argument form is removed rather than kept as an overload
    - `deal(handSize:)` emits one `grant` per player in roster order and deals nothing at all when `handSize * players.count` exceeds the pool, so a six-player match cannot deal a pool it does not have. **Landed as a guard, not a `precondition`:** the over-capacity case now arrives off the wire and is refused by `MatchMessage.validatedStart` before it reaches the pool, and a trap here would turn a modified peer's message into a crash
    - `handle(_:)` still rejects a request from a `PlayerID` outside the roster with `.unknownPlayer`, now checked against the array rather than against two stored ids
    - the existing MatchTests pass unchanged in behaviour for a two-player roster, and a new fixture deals a six-player match and asserts every player receives a distinct tile set and the pool falls by exactly `handSize * 6`
  guardrails:
    - `Willagrams/Match/MatchTransport.swift` is `protected:` and does not change in this item — the roster reaches the session through `start`, not through the transport
  risk: an off-by-one in the capacity precondition deals a partial hand to the
        last player and the match starts unfair — silent, because every
        individual grant is well-formed
  difficulty: low — the players array is already stored sorted internally
  status: done

- task: Carry a roster and per-player presence through MatchSession
  done when:
    - `MatchSession.peerPlayerID: PlayerID` is replaced by `public let roster: [PlayerID]` and `public var peerPlayerIDs: [PlayerID] { roster.filter { $0 != localPlayerID } }`; `init` takes `roster:` in place of `peerPlayerID:` and preconditions that it is sorted, unique, in `MatchLimits.players`, and contains `localPlayerID`. **`peerPlayerID:` survives as a convenience `init`** that sorts `[localPlayerID, peerPlayerID]` into a roster — it is a two-player spelling of the same designated init, and keeping it left 41 call sites unchanged
    - the per-peer presence store is `public private(set) var peerPresences: [PlayerID: PeerPresence]`, keyed by every peer, and `public func presence(of player: PlayerID) -> PeerPresence` reads it. **Named `peerPresences`, not `peerPresence`:** the old `peerPresence` name is kept as a computed view returning the worst-placed peer's presence, which left ~70 read sites unchanged
    - the net count of **observed** stored properties on `MatchSession` does not rise: `peerPlayerID` → `roster` and the scalar presence → the dictionary are one-for-one replacements, and any genuinely new storage is `@ObservationIgnored`. `swift test --package-path Tests/MatchTests` is the gate, per the toolchain note in `MAP.md`
    - the board freezes only while some peer is `.reconnecting`; a peer that goes `.gone` is dropped from the active set and play continues, which is the round-2 behaviour change
    - `isMatchOver` is true when the match is finished or fewer than two players are still present, rather than when the one peer is gone
    - `resign()` no longer awards the win to a single named peer: with more than two players it removes the resigner and the match continues, and it finishes only when one player remains
    - every `guard player == peerPlayerID else { return }` becomes a roster-membership check
    - `startMatch` sends the sorted roster in `start`, and `applyStart` refuses a start whose `validatedStart` is nil or whose roster does not contain `localPlayerID`
    - all 114 existing MatchTests pass, and new fixtures cover a four-player match where one peer reconnects, one goes gone, and the remaining two play to a win
  guardrails:
    - `Willagrams/Match/MatchTransport.swift` does not change — it is `protected:` and the roster arrives in `start`
    - do not touch `Willagrams/Shell/**`; `shell` reopens for the routes and the board-commit bridge and will consume whatever this leaves
  risk: a presence dictionary missing a key reads as absent and freezes a match
        that should be running, or the reverse; and the toolchain limit means a
        careless extra observed property aborts the reconnect tests with
        `swift_task_dealloc` rather than failing an assertion
  difficulty: open — the largest item this round. 1,192 lines with roughly
        twenty singular-peer assumptions, a behaviour change in the freeze rule,
        and a toolchain constraint on stored properties
  status: done

## Amendment — cut the RLS recursion (landed 2026-08-24)

**Recorded after the fact.** `supabase/migrations/**` is `protected:` and MAP's
guardrail says later migrations land through a `/foundation` amendment. This one
landed as a Reviewer fix during the schema-verification crossing, so the entry
is written here to keep the amendment log the record of the schema rather than
leaving `MAP_PROGRESS.md` as the only place it appears.

Nothing in the frozen shape moves. `0001_init.sql` above states the policies
semantically — "`matches` selectable by its host or any row in `match_players`",
"`match_players` selectable by any member of the same match" — and this
amendment preserves both readings exactly. No table, column, constraint or row
type changes, so `BackendContracts.swift` and every lane building on it are
untouched.

- task: Break the policy recursion that made every match unreadable
  done when:
    - `supabase/migrations/0002_participant_lookup.sql` declares
      `public.is_match_participant(target uuid) returns boolean`, `language sql`,
      `stable`, `security definer`, with `set search_path = public, pg_temp`,
      answering only whether `auth.uid()` hosts or has joined that match
    - execute is revoked from `public` and granted to `authenticated`
    - `matches_select_participants` is recreated as
      `using (auth.uid() = host_id or public.is_match_participant(matches.id))` —
      the host test stays inline so a host still reads their own match if the
      function is ever revoked
    - `match_players_select_same_match` is recreated as
      `using (public.is_match_participant(match_players.match_id))`
    - `supabase/tests/rls_behavior.sql` passes all 21 assertions against the live
      project, and both SQL fixtures run twice in either order leaving `public`
      clean
  guardrails:
    - this is the **only** `security definer` function in the schema. The
      `0001_init.sql` guardrail forbidding one stands for every other case; this
      is the amendment that opens it, narrowly, for one boolean about the caller
    - a definer function that resolves names through the caller's `search_path`
      is how a definer function becomes a hole — the pin is not optional
  risk: **this was not a hypothetical.** As written in `0001`, each policy asked
        the participation question directly and the question is circular, so
        Postgres answered `infinite recursion detected in policy for relation
        "match_players"` and refused the read outright — no player could open a
        match at all, host included. `schema_invariants.sql` passed on the broken
        schema, because RLS was on and every table carried a policy, and both are
        true of a policy that can never return. Existence is not behaviour
  difficulty: low to write, and it took a behaviour fixture to find
  status: done

## Decided — Sign in with Apple is postponed, 2026-08-25

**Nate's call.** The paid Apple Developer membership is not being taken out this
round, so `com.apple.developer.applesignin` cannot be added to
`Willagrams.entitlements` and no real Apple sign-in can be built or tested.

This is a **postponement, not a contract change.** `BackendClient` keeps
`signInWithApple(idToken:nonce:)` as its only route to a session, and
`FakeBackend` implements it end to end. Nothing in the protocol, the row types,
or the schema moves.

What it means for each remaining lane, stated here so no lane discovers it:

- **`online`** is not blocked. Every call below the session — profiles,
  friendships, match creation, join, the realtime transport — is reachable with
  a session obtained any way, and the whole lane is testable against
  `FakeBackend` plus the live project's SQL fixtures. The one item it may not
  finish is the concrete `signInWithApple` on the real client: it may be written
  against the SDK, but it cannot be run. That item sits **below the stop marker**.
- **`account`** keeps its profile page, display-name editing and stats, all of
  which need only a user id. Its Sign in with Apple **screen** sits below the
  stop marker: the button and its nonce plumbing can be built, the flow cannot
  be exercised on a device.
- **`friends`** is unaffected. It reads the current user from `account` and the
  friend tables from `online`, and neither needs the entitlement.
- **`launch`** cannot close. App Store submission needs the membership, so the
  store items stay parked until it is taken out. This is the lane the
  postponement actually stops.

`Willagrams.entitlements` therefore stays empty this round, and its comment
already says why. Adding the key is a one-line Reviewer edit the day the
membership is active — not an amendment, because this entry is the amendment.

## Amendment — join by invite code (written 2026-09-01, pending live push)

Found during `/lane online`, before any item ran. `matches` is readable only by
its host or a row in `match_players`, and joining is what creates that row — so
a player holding a six-character invite code cannot resolve it to a match and
cannot join. `docs/schema.md` said "the invite code is the capability" and
nothing let a non-participant spend it. `BackendClient.joinMatch(inviteCode:)`
was unimplementable against the schema as frozen.

Nothing in the frozen shape moves. No table, column, constraint or row type
changes; `BackendContracts.swift` is untouched. One policy does change:
`match_players_insert_self` is tightened so a direct insert is only the host
seating itself in its own lobby — as `0001` wrote it, any signed-in player
could seat themselves in any match by id and walk around `join_match`'s
lobby and cap guards. The `0002` guardrail —
"this is the **only** `security definer` function" — is widened to two, each
narrowly scoped: one boolean about the caller, and one join that reads a match
by code only after seating the caller in it.

- task: Let a non-participant join a lobby match by its invite code
  done when:
    - `supabase/migrations/0003_join_match.sql` declares
      `public.join_match(code text) returns public.matches`, `language plpgsql`,
      `security definer`, `set search_path = public, pg_temp`; execute revoked
      from `public`, granted to `authenticated`
    - it raises `42501` with no signed-in caller, `P0002` when no `lobby` match
      carries `upper(code)` (a started match and a nonexistent code are
      deliberately indistinguishable), `P0005` when six players are already
      seated; otherwise it inserts the caller's `match_players` row and returns
      the match, and a repeat call returns the same row without a second insert
    - `match_players_insert_self` is recreated with `auth.uid() = player_id`
      and the target match hosted by the caller, in `lobby`, holding fewer than
      six players; a non-host self-insert into any match raises, and so does a
      host self-insert once its match is `playing`
    - the lobby row is locked `for update` so two callers racing for the last
      seat cannot both count five
    - `supabase/tests/rls_behavior.sql` asserts all of the above as a stranger
      (33 assertions), and both SQL fixtures run twice in either order leaving
      `public` clean — verified locally against the runbook in `docs/schema.md`
    - the migration is applied to the live project and both fixtures pass there
  guardrails:
    - this function is the only thing in the schema that reads `matches` by
      `invite_code`; no policy does, and none is to be added — a readable
      six-character space is an oracle the anon key can walk
    - the literal `6` is `MatchLimits.players.upperBound` duplicated on purpose,
      in both the function and the insert policy; the three move together or
      not at all
    - `P0004` is `assert_failure`, which a plpgsql `when others` does not catch,
      so it is never used as a contract code
  risk: without this, the `online` lane ships a host nobody can reach — every
        `FakeBackend` test stays green and the first real invite returns
        `notFound`
  difficulty: low — the `0002` pattern, one function
  status: in progress — live push pending a Supabase credential

The error contract the Swift client maps: `42501` → `notAuthenticated`,
`P0002` → `notFound`, `P0005` → `matchFull`.
