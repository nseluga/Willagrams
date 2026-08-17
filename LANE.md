# Willagrams — Lane: shell

Lane: shell — App shell: launch, main menu, solo practice mode, host/join flow, in-match HUD, results screen, navigation. Settings screens themselves belong to the settings lane; shell navigates into them.

Protected — do not edit. Stop and report if an item requires changing one:
  Sources/WillagramsRules/Contracts.swift
  Sources/WillagramsRules/BoardAnalysis.swift
  Sources/WillagramsRules/Pool.swift
  Sources/WillagramsRules/GameState.swift
  Sources/WillagramsRules/MatchMessage.swift
  Sources/WillagramsRules/WordList.swift
  Sources/WillagramsRules/Resources/dictionary.txt
  Tests/WillagramsRulesTests/**
  Willagrams/Style/DesignTokens.swift
  Willagrams/Style/Terminology.swift
  Willagrams.entitlements
  Package.swift

Frozen contracts — build and test against these; they will not move:
  style — Willagrams/Style/DesignTokens.swift (token key names; values may change under you). Terminology strings in Willagrams/Style/Terminology.swift. Verified by Tests/StyleTests (source-grep suite, no fixture).
  board — Willagrams/Board/BoardView.swift, BoardCamera, BoardLayout, BoardModel. Merged and closed. Fixture: Tests/BoardTests.
  match — Willagrams/Match/MatchSession.swift, MatchTransport.swift, FakeTransport.swift, HostPool.swift, MatchCodec.swift. Merged and closed. Golden fixture: Tests/WillagramsRulesTests/Fixtures/wire-v1.json.

Test against the fixture, not the producing lane. Do not wait for it to exist.

Items scope to this lane only. An item requiring a `protected:` change is not a
lane item — it is an amendment request.

## Status

Every dependency except `settings` has merged. The app currently launches into
`BoardHarness`, a throwaway in `Willagrams/App/WillagramsApp.swift` whose own
comment says to delete it the moment this lane authors that file. This round
turns seven merged libraries into an app that plays one complete solo match end
to end, driven from a single persona.

## Global rules

- **No SwiftUI view in this repo can be tested headlessly.** The nested test
  packages build for macOS and symlink in non-View files only. Every decision,
  transition and derived string therefore lives in an observable model or a pure
  function; views stay thin enough that nothing untested hides in them. A view
  holding a branch that changes behavior is a defect, not a style choice.
- Never `import GameKit`. Every file under `Willagrams/Match/**` carries that
  header rule and this lane inherits it. Real Game Center is match items 6–8 and
  is not in this round.
- `Terminology.swift` is frozen and is the IP fence. Strings it does not define —
  "Play", "Solo Practice", "Rematch", "Main Menu", "Resign" — are declared local
  to the view that uses them, following the `BoardView.recenterLabel` precedent
  for chrome that is not a game concept.
- `TerminologyFenceTests` greps all of `Willagrams/**` for banned vocabulary
  (bunch, split, peel, dump, banana, rotten). Menu and results copy is scanned.
- Landscape-only, iPhone and iPad. Never add a portrait orientation or assume a
  fixed viewport size; `BoardHarness` hard-coded 1366x1024 and it is being
  deleted, not imitated.
- Two players per match. There is exactly one peer.
- Do not build a difficulty selector, a bot, or any opponent intelligence. A
  silent placeholder peer is the whole opponent this round; the `bot` lane owns
  the rest.

## Two granted amendments

`MAP.md` grants this lane two edits outside its `owns:`. Agents do **not** stop
at the fence for these, and for nothing else:

- `Willagrams/Match/MatchSession.swift` and `Tests/MatchTests/**` — item 2 only.
- The `init` signature of `Willagrams/Board/BoardView.swift` — item 3 only. No
  other file under `Willagrams/Board/**` is opened.

Any further path outside `owns:` is a fresh amendment: stop and report.

---

- task: Create the shell route model and its headless test package. Add
    `Willagrams/Shell/AppRoute.swift` with an `AppRoute` enum whose cases carry
    their own data (`.menu`, `.countdown`, `.match`, `.results`) so the current
    screen and the state it renders cannot disagree, and
    `Willagrams/Shell/ShellModel.swift`, a `@MainActor @Observable` object owning
    the current route and the transitions between them. Stand up
    `Tests/ShellTests/` as a nested standalone SwiftPM package on the
    `Tests/MatchTests` pattern: a directory symlink `ShellSrc` →
    `../../Willagrams/Shell`, a `Package.swift` declaring
    `platforms: [.iOS(.v17), .macOS(.v14)]`, depending on `../..` for
    `WillagramsRules`, with the test target at `Cases/`. Symlink only non-View
    files, exactly as MatchTests does — the moment a SwiftUI view enters the
    target the suite stops building for macOS.
  guardrails:
    - Never add a test target to the root `Package.swift` — it is protected
    - `ShellModel` must not import SwiftUI; if it needs to, the design is wrong
    - No route transition may be reachable from a view directly — views call
      ShellModel, never mutate a route themselves
  done when:
    - `swift test --package-path Tests/ShellTests` builds and passes on macOS with no simulator
    - A test drives ShellModel from `.menu` through `.countdown` to `.match` and asserts the route after each transition, instantiating no SwiftUI view
    - `swift test` at the repo root still discovers and passes the existing engine suite, unaffected by the new nested package
  status: done

- task: Deal the opening hand. `MatchSession` receives `startingHandSize` off the
    wire at `applyStart` and clamps it, but never gives either player a tile —
    the deferral is the `ponytail:` comment at
    `Willagrams/Match/MatchSession.swift:673`. When the countdown reaches zero,
    the host draws `startingHandSize` tiles per player from its `HostPool` and
    sends each player a `grant`. Reuse the existing
    `MatchMessage.grant(player:tiles:)` case rather than adding a wire case —
    `MatchMessage.swift` is protected and its own comment states that adding a
    case is a wire break requiring a `WireFormat` bump. The subtlety is the
    receiving side: `applyGrant` currently routes tiles into `pendingDrawTiles`
    when `requestedByLocal` is false, which is correct for a peer-initiated draw
    and wrong for an opening deal. A grant arriving while status is
    `.countdown` must land in the hand directly. Leave the playing-phase path
    byte-for-byte unchanged.
  guardrails:
    - Do not add, reorder, or rename a `MatchMessage` case — that file is protected
    - Do not change `WireFormat.current`; this item ships on wire v1
    - The playing-phase draw obligation must survive untouched — a peer draw still holds tiles until the local player presses Draw
    - Leave a `ponytail:` comment naming the phase-dependent interpretation as the known ceiling, with a distinct `deal` case at the pending wire v2 amendment as the upgrade path
  done when:
    - When the countdown reaches zero both players' hands contain exactly `startingHandSize` tiles, and `pendingDrawTiles` is empty
    - A grant received while status is `.playing` still holds its tiles in `pendingDrawTiles` until `draw()` is called
    - A grant that arrives during `.countdown` and one that arrives during `.playing` produce different placements of the same bytes, asserted in one test that sends both
    - The host's pool is reduced by exactly `startingHandSize * 2` after the deal, with no tile appearing in two hands
    - Existing passing match tests remain passing
  caution: true
  status: done
  parallel-group: a

- task: Give `BoardView` a way to report its state to its owner. Today
    `init(board:camera:dictionary:inputLocked:)` takes the board **by value**
    into `private @State`, and SwiftUI reads a `@State` initial value once — so
    nothing can be delivered to the board after construction and nothing can be
    read back out. The shell needs both: to hand dealt and drawn tiles in, and
    to read `BoardModel.canDraw` out for the HUD. Change the `init` signature to
    expose the board state to its owner, keeping `BoardModel` as the single
    holder of validation rather than duplicating it shell-side. Update
    `BoardHarness`'s call site in the same edit so the app still builds; it is
    deleted in item 4 regardless.
  guardrails:
    - Touch no file under `Willagrams/Board/**` except `BoardView.swift` — the amendment covers that file alone
    - `BoardModel` stays the only thing that answers whether the player may draw; never recompute validation in the shell
    - Do not change board behavior — this item moves a seam, it does not alter what the board does
    - `Tests/BoardTests` must not need editing; if it does, the signature change reached further than intended
  done when:
    - An owner outside `BoardView` can supply tiles after construction and see them rendered, verified by a test on the state type rather than the view
    - An owner outside `BoardView` can read draw-eligibility without recomputing it
    - `Tests/BoardTests` passes unedited, and the input lock and live invalid-word tinting behave as before
    - Pan, pinch-zoom, tile drag, snap and double-tap selection are confirmed by hand on a device and reported in the item's summary. No test in this repository reaches a gesture, so a green suite is not evidence here — say so plainly rather than inferring it
  status: done — one criterion outstanding: by-hand gesture pass on a device
  parallel-group: a

- task: Author the real app root. Rewrite
    `Willagrams/App/WillagramsApp.swift` so `WindowGroup` hosts a new
    `Willagrams/Shell/ShellRootView.swift` that switches on `ShellModel`'s route,
    keeping the existing `BrandFonts.registerOnce()` call in `init`. Delete
    `BoardHarness` and everything below it in that file, as its own comment
    instructs. Use no `NavigationStack`: the screens are full-bleed modes rather
    than a drill-down hierarchy, a nav bar would be hidden on every screen, and a
    `NavigationStack` path lives inside a View and so cannot be tested by this
    repo's macOS test packages.
  guardrails:
    - `BoardHarness` and its fixed 20260815 seed leave the repo entirely — no renaming it to a debug path
    - `ShellRootView` holds no navigation decision of its own; it renders whatever route ShellModel reports
    - Keep `BrandFonts.registerOnce()` on the launch path or every custom font silently falls back
  done when:
    - The app launches to the main menu, and `BoardHarness` appears nowhere in the repository
    - A grep for `NavigationStack` under `Willagrams/Shell/**` and `Willagrams/App/**` returns nothing
    - `BrandFonts.registerOnce()` runs exactly once per launch, however many views are constructed
  status: done

- task: Build the main menu screen at
    `Willagrams/Shell/MenuView.swift` — the app title treatment and a single
    Solo Practice action, styled from `DesignTokens` (`Palette.canvasTop`/
    `canvasBottom` for the ground, `Typography.display` with `displayTracking`
    for the title, `PrimaryButtonStyle` via `.brandPrimary` for the action).
    Host and Join are deliberately absent this round: there is no
    `GKMatchTransport` behind them, and a disabled control is a claim that has to
    be maintained and then removed. `StyleGallery` is already a public view and
    is worth a quiet debug route in, but not a visible menu row.
  guardrails:
    - No Host, Join, or Settings row, enabled or disabled — the menu offers only what works
    - Menu copy is declared locally, never added to the frozen `Terminology.swift`
    - Hard-code no color, font size, spacing or duration; every value comes from a `DesignTokens` key
  done when:
    - Activating Solo Practice moves ShellModel's route off `.menu`, asserted without instantiating a view
    - The menu renders in both landscape orientations at iPhone and iPad widths with nothing clipped or overlapping
    - `TerminologyFenceTests` passes with the new copy in the tree
  status: not started

- task: Construct a solo practice session.
    Add `Willagrams/Shell/SoloMatch.swift`, a factory that builds a playable
    single-persona match: a `FakeTransport.pair`, a `MatchSession` for the local
    end, a `HostPool`, and a silent placeholder peer that receives messages and
    never acts. Two traps to handle explicitly. `HostPool.host(of:)` awards host
    to the lower `PlayerID` by `rawValue`, so choose the pair such that the local
    player is host, or `startMatch` silently no-ops and sets
    `lastNote = "only the host opens the match"`. And `HostPool` grants a tile to
    **each** player per draw event, so against a silent peer every draw burns two
    tiles and wastes one — size the solo pool so the player sees a full-length
    game rather than one that ends half way.
  guardrails:
    - The peer is silent, not smart — no word building, no draw scheduling, no difficulty parameter of any kind
    - Never branch `MatchSession` or `HostPool` on "is this solo"; solo is a transport-and-pool configuration, not a mode inside the engine
    - Local player must be host by construction, never by retrying after a no-op
  done when:
    - `startMatch` on a solo session reaches `.playing` and leaves `lastNote` nil, never the host rejection note
    - A solo match can be played from the opening deal to a win claim without the pool exhausting early, asserted by counting tiles consumed against pool size
    - Repeated draws each yield the local player exactly one tile, and no tile is ever held by both ends
  status: not started

- task: Build the countdown screen at
    `Willagrams/Shell/CountdownView.swift`, rendering
    `MatchStatus.countdown(secondsRemaining:)` from `MatchSession` with the
    frozen `Terminology.countdownTitle` string and the seconds remaining. The
    board is visible behind it, so the dealt tiles can be seen arriving
    underneath rather than appearing fully formed on a later screen — the
    animation itself belongs to the `tuning` lane, so present the surface it will
    animate into and add no motion here beyond what `DesignTokens.Motion`
    already defines.
  guardrails:
    - Never compute the countdown locally — render only what MatchSession reports, or the two devices will disagree
    - Do not author the deal animation; `tuning` owns it. Leave the board visible and unobstructed underneath
    - Use `Terminology.countdownTitle` verbatim; do not introduce a second string for the same idea
  done when:
    - The countdown displays each second reported by MatchSession and clears when status becomes `.playing`, asserted against an injected clock rather than by waiting
    - The board is visible behind the countdown for its whole duration
    - A countdown that reaches zero leaves no overlay behind, at any starting value including one second
  status: not started

- task: Wire the match session to the board. `ShellModel` observes
    `MatchSession` and drives the `BoardView` seam opened in item 3: dealt tiles
    at countdown end and drawn tiles mid-match are delivered onto the board via
    `BoardLayout.opening` and `BoardLayout.delivered` respectively, and
    `BoardModel.canDraw` is read back out for the HUD. `BoardLayout` already
    places an opening in a spaced block and lands drawn tiles in free space below
    the current view, so this item routes data rather than computing geometry.
  guardrails:
    - Never place a tile by computing coordinates in the shell — `BoardLayout` owns placement
    - Never duplicate the dictionary or re-derive word validity shell-side; `BoardModel` is the single answer
    - A tile must exist in exactly one place; delivering to the board removes it from wherever it was held
  done when:
    - Tiles dealt at countdown end appear on the board in a `BoardLayout.opening` arrangement, with no two tiles adjacent enough to form a word
    - Accepting a mid-match draw lands the new tiles in free space within the current viewport, not off screen
    - The HUD's draw-eligibility reflects `BoardModel.canDraw` and changes as the player makes and breaks words
    - Existing passing board and match tests remain passing
  status: not started

- task: Build the in-match HUD at `Willagrams/Shell/MatchHUD.swift` — tiles
    remaining in the pool, a Draw action enabled only when draw-eligibility is
    true, a Swap action, and a quiet Resign. Pool, Draw and Swap use the frozen
    `Terminology` strings; Resign is local chrome. Deliberately absent: any
    display of the opponent's progress or presence. There is no opponent worth
    reporting on this round, and it would be untested chrome.
  guardrails:
    - Never show or imply the opponent's board, tile count, or progress
    - Draw must be unavailable, not merely ignored, while draw-eligibility is false — a tappable control that does nothing is a bug
    - Resign must be hard to hit by accident during play; it is a destructive action on a match in progress
    - The HUD must not obscure the board's own recenter control, which `BoardView` overlays top-trailing
  done when:
    - The pool count matches the session's remaining tiles after every draw and swap
    - Draw is unavailable while the board holds an invalid word and becomes available the moment the board is valid
    - Swap returns a tile and yields a replacement, and is refused without disturbing the pool when too few tiles remain
    - Resign ends the match and moves ShellModel's route to `.results`
  status: not started

- task: Build the results screen at
    `Willagrams/Shell/ResultsView.swift`, reading `MatchSession.winner`,
    `isMatchOver` and `winningPlacements`. Show who won — using the frozen
    `Terminology.winCall` when the local player won — with the final board
    behind it, and offer two actions: Rematch and Main Menu. Handle the
    no-winner terminal states the match lane already ships: a resign-vanish and
    a peer that never returns both leave `winner` nil, and neither is a loss.
  guardrails:
    - Never render a winner when `winner` is nil — no-winner is a real outcome, not an error or a loss
    - Main Menu must tear the match down, not leave it running behind the menu
    - Results copy other than `winCall` is local chrome, never added to `Terminology.swift`
  done when:
    - A local win shows the `winCall` string; a peer win shows the peer as winner; a nil winner shows neither player as winner
    - Main Menu returns ShellModel's route to `.menu` and the previous session is released
    - The final board is visible behind the result and cannot be played on
  status: not started

- task: Implement Rematch — same players, fresh match. Build a new
    `FakeTransport.pair`, `MatchSession` and `HostPool` with the same
    `PlayerID`s, so host ordering stays stable, and a **new seed**, so practice
    is not memorising one deal. A full rebuild rather than resetting the existing
    session is forced by contract, not preference:
    `Willagrams/Match/MatchTransport.swift:47` states each stream has exactly one
    consumer per endpoint, so a live transport cannot be handed to a second
    `MatchSession`. Resetting `MatchSession` in place would additionally be a
    change to its terminal-state behaviour, which the granted amendment does not
    cover. Route Rematch through the same construction path as starting a match
    so there is one code path, not two — and tear the old session and transport
    down explicitly, or the previous stream-iteration task leaks and compounds
    across repeated rematches.
  guardrails:
    - Never hand an existing transport to a new `MatchSession` — one consumer per stream, per its own contract
    - Do not add a reset or replay path to `MatchSession`; that is outside the granted amendment
    - Never reuse the previous seed — an identical pool makes practice into memorisation
    - The old session must be torn down before the new one starts, not left to deallocate whenever
  done when:
    - Rematch starts a fresh match with the same two `PlayerID`s and a different seed, with the local player still host
    - Ten consecutive rematches leave no orphaned stream-iteration task and no growth in live session count
    - A message from the previous match's transport can never reach the new session, asserted by sending one after the rebuild
    - No state from the finished match is visible in the new one — hand, board, pool count and status all start fresh
  caution: true
  status: not started

## Not yet specified

- Whether the shell should expose a debug route into `StyleGallery`, and how it
  is reached without a visible menu row — revisit after item 5.

## Out of scope

- **Settings navigation and any options screen** — the `settings` lane has not
  merged and is itself blocked on the wire v2 amendment. Shell navigates into
  settings in a later round.
- **Real Game Center — Host and Join** — match items 6–8 (`GameCenterAuth`,
  `GKMatchTransport`, real reconnect) are unbuilt and need two physical devices
  and two Game Center accounts to verify. Nothing in this round imports GameKit.
- **The CPU opponent and its difficulty selector** — the `bot` lane owns the
  solver, its difficulty model, and the UI for choosing it. Shell ships a silent
  placeholder peer.
- **The opening-deal animation and all polish motion** — the `tuning` lane owns
  it. Shell presents the surface; tuning makes the arrival look right.
- **Opponent progress display** — deliberately never shown, per the match design
  and this round's HUD decision.
- **A distinct `deal` wire case** — deferred to the pending wire v2 amendment,
  where it costs nothing extra. Item 2 ships on v1 by reusing `grant`.
