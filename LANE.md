# Willagrams — Lane: bot, round 2

Lane: bot — The CPU opponent for solo play: a heuristic grid solver that holds tiles, builds a valid connected board from them, draws when its board is complete, and races the player. Owns its difficulty model and the UI for choosing a difficulty. Sits behind the transport seam exactly as a remote peer does, which is what lets solo play ship in Release.

Owned — this lane's items live inside these paths:
  Willagrams/Bot/**
  Tests/BotTests/**

Stop and report if an item requires changing a path outside them:
  protected — Sources/WillagramsRules/Contracts.swift, BoardAnalysis.swift, Pool.swift, GameState.swift, MatchMessage.swift, MatchOptions.swift, WordList.swift, Resources/dictionary.txt; Tests/WillagramsRulesTests/**; Willagrams/Match/MatchTransport.swift; Willagrams/Style/DesignTokens.swift; Willagrams/Style/Terminology.swift; Willagrams.entitlements; Package.swift; supabase/migrations/**; Willagrams/Online/BackendContracts.swift; Willagrams/Audio/AudioPlayer.swift
  another lane's — Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md (style) · Willagrams/Board/**, Tests/BoardTests/** (board) · Willagrams/Match/**, Tests/MatchTests/** (match) · Willagrams/Settings/**, Tests/SettingsTests/** (settings) · Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/** (shell) · Willagrams/Online/**, Tests/OnlineTests/**, supabase/** (online) · Willagrams/Account/**, Tests/AccountTests/** (account) · Willagrams/Friends/**, Tests/FriendsTests/** (friends) · Willagrams/Audio/**, Tests/AudioTests/** (audio) · fastlane/**, docs/store/** (launch)
  unowned — `.` (repo root: MAP.md, Package.swift, README, .gitignore, Willagrams.entitlements) · `.claude/**` · docs/*.md · progress/** · Sources/WillagramsRules/** and Tests/WillagramsRulesTests/** · Willagrams.xcodeproj/**

Frozen contracts — build and test against these; they will not move:
  match — Willagrams/Match/MatchTransport.swift (the protocol this lane conforms to) and MatchSession's public surface (the API the bot plays through). Fixture: Tests/MatchTests (124) and the golden wire Tests/WillagramsRulesTests/Fixtures/wire-v3.json.
  style — Willagrams/Style/DesignTokens.swift (token key names; values may change under you) and Willagrams/Style/Terminology.swift. Fixture: Tests/StyleTests (source-grep suite, 30).
  engine — no lane edge, fenced under `protected:`: BoardAnalysis word extraction and connectivity, Contracts (Tile, Coord, Placement, Board), GameState, WordList, MatchOptions. Fixture: Tests/WillagramsRulesTests (53).

Test against the fixture, not the producing lane. Do not wait for it to exist.

Items scope to this lane only. An item requiring a `protected:` change is not a
lane item — it is an amendment request.

## Status

Greenfield: `Willagrams/Bot/` and `Tests/BotTests/` do not exist. Both
`depends on:` edges are parallel and both contracts are already merged on
`integration`, so nothing here waits on another lane.

This lane is what makes solo play ship. `Willagrams/Shell/SoloMatch.swift` is
fenced `#if DEBUG` because `FakeTransport` is, so the match screen the shell
lane is composing this round cannot ship in a Release build. `LocalMatchLink`
and `BotMatch` are the shipping replacement for that pair.

**The bot is player 2, not a mode inside the engine.** It drives its own
`MatchSession` as a *guest* over an in-memory link. The human's session is host
and holds the `HostPool`, so it remains the sole authority for every tile. This
lane builds no rules — it builds an opponent that plays by the ones already
frozen.

## Global rules

- **Every move goes through the bot's own `MatchSession`.** The brain never
  writes `state.board` or `state.hand`. A guest cannot mint tiles — `receive`
  drops a `.grant` that does not name it — and `place`/`recall`/`draw`/`swap`
  carry the frozen rules already. The bot obeys them structurally, not by
  re-implementing them.
- **`FakeTransport` is out of bounds.** It is `#if DEBUG` by design and must
  never be reachable from a shipping path. Nothing in `Willagrams/Bot/**` may
  reference it, and no file in this lane may fence its own type behind
  `#if DEBUG` — that fence is the exact problem this lane exists to remove.
- **The search runs off the main actor.** `MatchSession` is `@MainActor`; a rack
  search on the main actor hitches the board the human is dragging on.
- **No SwiftUI view in this repo can be tested headlessly.** `Tests/BotTests`
  builds for macOS and its `Bot` target must `exclude:` every View file, exactly
  as `Tests/ShellTests/Package.swift` does. A new View file not added to that
  list stops the package building. Every decision, transition and derived string
  therefore lives in a model or a static constant; views hold no branch that
  changes behavior.
- **Never `import GameKit`.**
  `Tests/MatchTests/Cases/SourceGuardrailTests.swift` asserts no file ever does.
- **`Terminology.swift` is frozen and is the IP fence.** Game concepts use
  `Terminology.pool`, `.draw`, `.swap`, `.winCall`. Screen chrome it does not
  define is declared local to the view that uses it, following the
  `BoardView.recenterLabel` precedent. The Bananagrams vocabulary (Bunch, Split,
  Peel, Dump, Bananas, Rotten) must never appear in player-facing copy.
- **⚠️ `MatchSession` is at a Swift 6.3.3 toolchain limit**, and it is `match`'s
  file, not this lane's. If an item appears to need a stored property there,
  stop and report it as an amendment request.

---

- task: |
    Build the shipping in-memory transport, and the test package that proves it.

    New `Willagrams/Bot/LocalMatchLink.swift`: an actor conforming to
    `MatchTransport`, with a `pair(_:_:)` factory returning two endpoints wired
    to each other in memory. It must honour exactly the semantics the protocol
    documents on itself — a single subscription per stream, unbounded buffering
    so elements produced before a consumer starts iterating are still delivered
    in order, a `send` that never suspends on a slow reader, and both streams on
    both endpoints finishing once either end calls `leave()`, after buffered
    elements drain. `Willagrams/Match/FakeTransport.swift` is the working
    reference for the delivery mechanics; read it, do not import it. Two
    deliberate differences: no drop filter, and no `#if DEBUG` anywhere.

    Also create the nested SwiftPM package `Tests/BotTests/`, modelled on
    `Tests/ShellTests/Package.swift`: the path dependency carries
    `name: "Willagrams"` (a bare `.package(path:)` resolves to the worktree
    directory name and the product lookup fails), symlinked source directories
    rather than copies, a macOS-buildable `Bot` target with an `exclude:` list
    for SwiftUI files, and a `BotTests` test target.
  guardrails:
    - Nothing in `Willagrams/Bot/**` references `FakeTransport`, and no type in this lane is fenced behind `#if DEBUG`
    - `MatchTransport.swift` is `protected:` — conform to it, never change it
    - Source directories in the test package are symlinked, never copied; this lane consumes `Willagrams/Match` and must not edit it
  done when:
    - Two endpoints from `pair` exchange messages in both directions, and a message sent before any consumer begins iterating is still delivered, in order, on first iteration
    - `leave()` on either endpoint finishes both endpoints' `inboundMessages` and `peerConnectionStates` after buffered elements drain, so a `for await` loop over either ends rather than hanging; a subsequent `send` throws `MatchTransportError.peerDisconnected`
    - The surviving endpoint observes `.disconnected` naming the endpoint that left
    - `swift test --package-path Tests/BotTests` runs and passes
  status: done

- task: |
    Build the bot's end of the wire — connected, dealt to, playing nothing.

    New `Willagrams/Bot/BotMatch.swift`, `@MainActor`, modelled on
    `Willagrams/Shell/SoloMatch.swift` but shipping rather than `#if DEBUG`. It
    creates a `LocalMatchLink` pair, exposes one endpoint for the caller to
    build the human's `MatchSession` on, and builds the bot's own guest
    `MatchSession` on the other. The two `PlayerID`s are chosen so that running
    the real `HostPool.host(of:)` election names the *human* — run the election,
    do not assert a string ordering, exactly as `SoloMatch` does. Exposes the
    bot's session, the human-side transport, and `leave()`, which tears down the
    bot's session and then the link.

    `MatchSession` already iterates its own inbound stream, and the protocol
    permits exactly one consumer per stream, so `BotMatch` adds no pump of its
    own. This item makes the bot present, dealt to, and silent; item 3 gives it
    a brain.
  guardrails:
    - The human end must always win the host election — a bot holding the `HostPool` would mint its own tiles and the match would be unfalsifiable
    - Exactly one consumer per stream; `BotMatch` must not iterate a stream `MatchSession` is already iterating
    - `leave()` is safe to call twice and leaves nothing running
    - Do not add stored properties to `MatchSession` — another lane's file, and at a toolchain limit
  done when:
    - Starting the match from the human side leaves the bot's session holding exactly `startingHandSize` tiles, and no tile id appears in both racks
    - `HostPool.host(of:)` over the two ids names the human, proven by running the election rather than by asserting an ordering
    - After `leave()`, a send from the human endpoint throws `peerDisconnected` and the bot session's inbound iteration has ended
    - Existing passing tests remain passing
  status: done

- task: |
    Give the bot a difficulty model and a brain that plays the simplest way.

    New `Willagrams/Bot/BotDifficulty.swift` — a `Sendable`, `Equatable` struct
    carrying `ladderDepth: Int` (0 extend · 1 repair · 2 rebuild · 3 swap),
    `thinkDelay: Duration`, and the stall-floor threshold, with `.easy`,
    `.medium` and `.hard` presets. These are the constants the pre-launch tuning
    pass edits; keep them in one place and name them.

    New `Willagrams/Bot/BotBrain.swift` — a background actor that drives the
    bot's `MatchSession` and keeps no copy of match state. Each tick: hop to the
    session's actor and read a snapshot (rack, board, `hasPendingDraw`,
    `canDraw`, `poolIsExhausted`, status). Then, in order:

      1. Tiles pending → call `draw()` to take them. This comes first because
         `place` throws `BoardActionError.drawPending` while a grant is waiting:
         the board is frozen until the tile is taken.
      2. `canDraw` is true → `poolIsExhausted ? claimWin() : draw()`.
      3. Otherwise attempt **rung 0, extend**: for each rack tile, for each empty
         cell orthogonally adjacent to a placed tile (or the origin on an empty
         board), place it and keep the placement only if
         `BoardAnalysis.validate` against the injected word list reports no
         invalid words. First legal placement wins.
      4. Nothing placed → wait for the next tick.

    Sleep `thinkDelay` between placements. Stop when status is `.finished`,
    including when the *human* wins and `.win` arrives at the bot's session.

    The snapshot can go stale between reading it and acting on it — a grant can
    land mid-search. Every placement therefore goes through
    `MatchSession.place(tileID:at:)`, and a thrown `BoardActionError` means
    re-snapshot and retry, never swallow.
  caution: true
  guardrails:
    - The brain claims a win only when `canDraw && poolIsExhausted`. Nothing on the wire verifies a win claim — `MatchSession` says so in its own comment — so this predicate is the only thing keeping the bot honest
    - The word list the bot's session validates against is the one derived from the match's `MatchOptions`, so the bot obeys the same minimum word length and dictionary as the player
    - The search never runs on the main actor
    - A thrown `BoardActionError` is never swallowed: it re-reads state and retries
    - The brain holds no mutable copy of the rack or the board between ticks
  done when:
    - Given a rack and an empty board, the bot places tiles until `canDraw` is true and then issues a `drawRequest`; the board it stopped on validates as one cluster with no invalid words
    - Across a full match run, the bot's rack plus its board accounts for exactly the tiles it was granted — no tile lost or duplicated when a grant lands mid-search
    - With the pool exhausted and the board complete the bot sends `.win` exactly once, and it sends none while the board is incomplete or the pool is not exhausted
    - When the human's `.win` arrives first, the brain issues no further moves and the bot's session names the human as winner
  status: not started

- task: |
    Add the two expensive rungs, and a floor so no bot can stall forever.

    Extend `BotBrain` with rung 1 and rung 2, each attempted only when the rung
    below it failed, and only when `difficulty.ladderDepth` permits it.

    **Rung 1 — local repair.** No single placement is legal, so free some space:
    choose the smallest set of placed tiles worth pulling — the shortest word
    touching the fewest crossings, plus any tile it orphans — recall them via
    `MatchSession.recall(from:)`, and re-place that set together with the stuck
    tile. Choosing *which* tiles to pull is the actual design work here; a repair
    that pulls too much thrashes and one that pulls too little never succeeds.

    **Rung 2 — full rebuild.** Recall every placed tile and re-solve the whole
    rack from scratch, under an explicit node or time budget so a 21-tile rack
    cannot hang the actor. Keep the best board found.

    Both rungs are transactional: if the attempt does not end with a board at
    least as good as the one it started from, restore the original placements.

    **Stall floor.** Count consecutive draws after which nothing was placed. At
    the threshold in `BotDifficulty`, the bot is allowed one attempt at one rung
    above its own depth, then the counter resets. This is what stops an easy bot
    from stalling permanently on a bad rack and turning the match into
    player-versus-nothing — which from the outside is indistinguishable from the
    bot being broken.
  caution: true
  guardrails:
    - A failed repair or rebuild restores the board it started from — a bot that leaves its board worse than it found it is a defect that only surfaces on the results screen, after the match
    - Rung 2 is bounded by an explicit declared budget, never by "search until done"
    - Neither rung may exceed `difficulty.ladderDepth`, except the single attempt the stall floor grants
    - Every recall goes through `MatchSession.recall(from:)`; the brain never writes the board directly
  done when:
    - A rack and board engineered so that no single tile placement is legal yields a placement at `ladderDepth` 1 and none at `ladderDepth` 0
    - A rebuild that finds nothing better leaves the board identical to the one before it ran, tile for tile and coordinate for coordinate
    - A bot at `ladderDepth` 0 given a stalling rack still places a tile within the stall-floor threshold, and the counter resets once it does
    - Rung 2 terminates and returns a board on a full 21-tile rack, within the budget it declares
  status: not started

- task: |
    Add the last rung: give a tile back.

    Extend `BotBrain` with rung 3, reached only when rungs 0–2 have all failed
    and `difficulty.ladderDepth` is 3. Return the least useful rack tile through
    `MatchSession.swap(_:)` — least useful by a letter-frequency heuristic over
    the current rack, preferring a tile no word the rack could form can use.

    Handle the two refusals the session already decodes and accounts for.
    `.swapDisabled` (the host turned swapping off in `MatchOptions`) and
    `.notEnoughTilesToSwap` (the pool is nearly out) both mean stop asking.
    `MatchSession.applyRejection` already gets the credit accounting right —
    neither refusal costs a draw credit — so the brain must not track credits
    itself.
  parallel-group: a
  guardrails:
    - A refused swap is never retried; the host's answer stands for the rest of the match
    - The brain does not track draw credits or count a swap as a draw — `MatchSession` owns that accounting
    - Swap is only ever reached after rungs 0–2 have failed, never as a first move
  done when:
    - A bot at `ladderDepth` 3 whose rack and board admit no placement sends exactly one `swapRequest`, and places a tile once the `swapGrant` lands
    - A bot answered with `.swapDisabled` sends no further swap request for the remainder of the match
    - A bot at `ladderDepth` 2 or below never sends a `swapRequest`
  status: not started

- task: |
    Build the difficulty screen.

    New `Willagrams/Bot/BotDifficultyView.swift` — a standalone SwiftUI screen
    offering the three `BotDifficulty` presets and a back control, reporting the
    chosen preset through a `(BotDifficulty) -> Void` closure the caller
    supplies. It starts nothing and owns no match state: it reports a choice.

    Shell owns navigation and will push to this screen; this lane ships the
    screen only. Every string and every decision lives in a small model or as
    static constants on the view's type, so the macOS test target can execute
    them — the view itself holds no branch. Add the new file to the `Bot`
    target's `exclude:` list in `Tests/BotTests/Package.swift` in the same edit.
  parallel-group: a
  guardrails:
    - No hardcoded color, spacing, font or duration — `DesignTokens` keys only
    - The screen owns no match state and starts no match
  done when:
    - Selecting each of the three presets invokes the closure exactly once with that preset, proven against the model rather than the view
    - The three presets differ in both `ladderDepth` and `thinkDelay`, and `.easy` carries the lowest depth and the longest delay
    - Every visual value in the file resolves through a `DesignTokens` key, and no player-facing string uses the Bananagrams vocabulary — confirmed by a source check
    - `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` succeeds
  status: not started

> **⚠️ AUTONOMOUS RUN — STOP HERE**

## Not yet specified

- Whether the three presets are far enough apart to feel like different opponents. Only playing answers it, and the player never sees the bot's board — they see the pool drain and the match end. The constants land as a first guess and the pre-launch tuning pass moves them. Revisit after item 6.

## Out of scope

- Wiring the bot into the app — the `AppRoute` case, the menu action and `MatchRun` building `BotMatch` instead of `SoloMatch` all live in `Willagrams/Shell/**`, another lane's `owns:`. Carried as two items placed after the stop marker on `lane/shell-r2`, to be run once this lane merges.
- A vocabulary ceiling as a third difficulty knob — a `MaxLengthWordList` decorator mirroring `MinimumLengthWordList` is about five lines, but it is invisible until the results screen and can backfire: a bot restricted to short words fills its board faster and therefore draws more. Deferred to the tuning pass.
- Showing the loser's board on the results screen — the *winner's* board already travels on `.win` and `ResultsModel.finalBoard` already renders it, so a player who loses to the bot already sees the bot's board. The loser's board would need a new `MatchMessage` field, which is `protected:` and a wire break to v4. Decided against this round.
- More than one bot in a match — the roster is two players this round.
- Verifying a win claim on the wire — `MatchSession` verifies nothing it receives and says so in its own comment. The bot self-polices instead. Hardening the host is `match`'s item, not this lane's.
- The device pass — no test in this repo reaches a SwiftUI view, so how the difficulty screen looks and whether the bot is fun to play against are Nate's to check in the simulator after the run.
