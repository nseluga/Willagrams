# Willagrams — polish lane

## Objective

Willagrams plays well on a landscape iPhone 13 mini and an iPad. Every screen fits, typing stays visible, board handling is forgiving, and a two-device online match starts only when the host presses Start, with both bags counting.

Lane done when:
- A two-device online match, created on one device and joined from the other, stays in the lobby on both until the creator presses Start, and both HUD bags show the same number from the deal to the end. Checked on two devices by hand; the model half is items 12–13.
- At 375pt landscape height (iPhone 13 mini / SE Simulator), Menu shows every action with no scrolling, and on an iPad Simulator the wordmark is visibly larger than today. Both are proven by `xcrun simctl io booted screenshot`, attached to the run summary.
- Every package suite is green run serially, no count below its floor, and `xcodebuild` reports BUILD SUCCEEDED on the merged branch.

Status: cut 2026-09-14 from `fix/phone-scroll` (Menu/Profile/Join/HostLobby scroll fix) after the two-device hand test on the iPad Pro 11 Simulator and a physical iPhone 13 mini. Wire v4 (`MatchMessage.poolCount`) is already landed. Items 12–13 build on it.

Lane: polish — The phone-polish tuning pass after the two-device hand test: proportional layout at landscape phone height, keyboard-visible typing, reachable validation, forgiving board handling (no snap-back, no fly-in, recenter that fits, drawn tiles near the board), unfriend, the early-start fix, the guest's bag count, and the WILLA word.

Owned — this lane's items live inside these paths:
  none of its own. `polish` is a pass, and every item edits a merged lane's paths (below)

Open — merged lanes. Wiring items may edit these; rebase onto `integration` first:
  Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md
  Willagrams/Board/**, Tests/BoardTests/**
  Willagrams/Match/**, Tests/MatchTests/**
  Willagrams/Settings/**, Tests/SettingsTests/**
  Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/**
  Willagrams/Online/**, Tests/OnlineTests/**, supabase/** (except supabase/migrations/**, protected)
  Willagrams/Account/**, Tests/AccountTests/**
  Willagrams/Friends/**, Tests/FriendsTests/**
  Willagrams/Bot/**, Tests/BotTests/**
  Willagrams/Audio/**, Tests/AudioTests/**

Stop and report if an item requires changing a path outside both lists:
  protected — Sources/WillagramsRules/** (Contracts, BoardAnalysis, Pool, GameState, MatchMessage, MatchOptions, WordList, Resources/dictionary.txt), Tests/WillagramsRulesTests/**, Willagrams/Match/MatchTransport.swift, Willagrams/Style/DesignTokens.swift (key names — values may change and keys may be added), Willagrams/Style/Terminology.swift, Willagrams.entitlements, Package.swift, supabase/migrations/**, Willagrams/Online/BackendContracts.swift, Willagrams/Audio/AudioPlayer.swift
  an unmerged lane's — fastlane/**, docs/store/** (launch)
  unowned — repo root files, .claude/**, docs/*.md, progress/**, Willagrams.xcodeproj/**

Frozen contracts — build and test against these; they will not move:
  Sources/WillagramsRules/MatchMessage.swift + Tests/WillagramsRulesTests/Fixtures/wire-v4.json (`poolCount(remaining: Int)`, `WireFormat.current == 4`)
  Willagrams/Match/MatchTransport.swift
  Willagrams/Online/BackendContracts.swift — a new backend call goes on a side protocol, as `Willagrams/Online/FriendRequestForgetting.swift` does
  Willagrams/Style/DesignTokens.swift key names

## Global rules

- **Tests.** Run each package serially on an idle machine, never while `xcodebuild` is running (a parallel run produced 22+ spurious timeouts):
  `swift test` (rules 53) · `swift test --package-path Tests/BoardTests` (253) · `Tests/MatchTests` (125) · `Tests/StyleTests` (30) · `Tests/ShellTests` (221) · `Tests/SettingsTests` (36) · `Tests/BotTests` (68, ~5 min) · `Tests/OnlineTests` (141, 1 known issue, live cases skip without a key) · `Tests/AudioTests` (19) · `Tests/AccountTests` (15) · `Tests/FriendsTests` (45).
  **These counts are floors.** A count may only go up. Never delete a passing test to hold a number.
- **Stale builds lie.** After changing any type in `Sources/WillagramsRules` or `Willagrams/Match`, run `swift package --package-path Tests/<pkg> clean` before trusting a red. A stale incremental build once misread an enum tag and timed out a correct test.
- **Views are not compiled by `swift test`.** After any SwiftUI edit, run `xcodebuild -project Willagrams.xcodeproj -scheme Willagrams -destination 'generic/platform=iOS Simulator' build`. The item isn't done until it says BUILD SUCCEEDED.
- **Nested-package symlinks.** `Tests/ShellTests/BoardSrc` and `Tests/ShellTests/StyleSrc` are directories of per-file symlinks. A new file under `Willagrams/Board/` or `Willagrams/Style/` stays invisible to ShellTests until it is symlinked there. Every other `*Src` is a directory symlink and picks new files up by itself.
- **One compact switch.** Landscape phone is `@Environment(\.verticalSizeClass) == .compact`. No `UIDevice` idiom checks, and no device-name sniffing. Size decisions live in plain structs (not `View`s), so ShellTests/StyleTests can assert on them.
- **`MatchSession` is at a Swift 6.3.3 toolchain limit.** One more *observed* stored property aborts MatchTests with `swift_task_dealloc`. New storage is `@ObservationIgnored`, published through `access`/`withMutation` the way `poolRemaining` is. Run MatchTests after every edit to that file.
- **Behavioral checks.** The Simulator can be booted, launched (`xcrun simctl launch`) and screenshotted (`xcrun simctl io booted screenshot`), but nothing can tap it (AXe cannot drive this Xcode). A screen reachable only by tapping is Nate's hand test: name it in the run summary with what to look at, and never claim it verified.
- Player-facing game vocabulary comes from `Terminology.swift`. No new game term may be inlined.
- Context: `CLAUDE.md`, `MAP.md` (lanes, landed amendments, the toolchain note), `docs/design/README.md` (visual truth), `/tmp/willagrams-handoff.md` (the hand test that found all of this).

## Out of scope

- A blocked player can delete their own block row. `friendships_delete_own` allows either end on any status; fixing it needs a migration, which goes through a separate `/foundation`.
- Sign in with Apple and the `launch` lane. Both wait on the paid Apple Developer membership.
- Ordering Realtime broadcast (FOUNDATION.md open risk). The guest's pool count is made order-proof by keeping the minimum, and nothing else here depends on order.

---

- task: One sizing mechanism for landscape phone, proven on Menu. Add token keys to `Willagrams/Style/DesignTokens.swift` (add only; never rename): a compact button font (`Typography.buttonCompact`) and a screen margin pair (`Space.screenMargin` / `Space.screenMarginCompact`). The compact margin is small enough to use the phone's edges; the safe area still applies. Teach the button styles in `Willagrams/Style/ButtonStyles.swift` to read `verticalSizeClass` and use the compact font and padding, so every screen's buttons shrink on a phone with no per-screen edit. Add a `.screenPadding()` modifier that applies the right margin, and replace `.padding(.xl)`-style screen margins in `Willagrams/Shell/MenuView.swift` with it. Rework MenuView around a plain `MenuLayout(size:)` struct. It returns the wordmark height (scaling with available height, capped at ~88pt on iPad so the iPad image is larger than today), the spacing, and whether the quiet actions sit in a two-column grid (compact height) or a column. The whole Menu then fits a 375pt-tall landscape phone without scrolling. Keep `ViewThatFits` as the large-Dynamic-Type fallback only.
  guardrails:
    - No existing DesignTokens key is renamed or removed; StyleTests' token guardrails stay green
    - The iPad layout at regular size class keeps its current structure. Only the sizes scale
    - The Menu still scrolls under the largest accessibility Dynamic Type sizes, rather than clipping
  done when:
    - A ShellTests case: `MenuLayout(size: CGSize(width: 812, height: 375))` returns a total content height ≤ 375 minus the landscape safe-area insets, with the two-column quiet grid; `MenuLayout(size: CGSize(width: 1194, height: 834))` returns a wordmark height larger than the pre-change constant and ≤ 88
    - A StyleTests case asserts the new token keys exist, with `Space.screenMarginCompact < Space.screenMargin`
    - `xcodebuild` BUILD SUCCEEDED, and an iPhone SE (3rd gen) or 13 mini landscape Simulator screenshot at launch shows every Menu action with no scroll indicator. The screenshot is attached to the run summary
    - Existing passing tests remain passing
  ui: true
  status: not started

- task: Apply the sizing mechanism to the remaining fixed-size screens. In `Willagrams/Shell/HostLobbyView.swift`, the invite-code font (44pt fixed, ~line 66) and the button `minHeight: 36` (~lines 106/112) scale down at compact height. In `ResultsView.swift`, the card padding (~line 78) becomes compact-aware. `CountdownView.swift` and `SoloSetupView.swift` adopt `.screenPadding()` in place of their fixed screen margins. Each screen's compact-vs-regular numbers come from item 1's mechanism, with no new per-screen constants where a token fits.
  guardrails:
    - The pinned header/actions pattern from `fix/phone-scroll` (ScrollView with pinned chrome) stays. This item tunes sizes and does not restructure scrolling
    - The regular-size-class (iPad) appearance of these screens does not shrink
  done when:
    - No `Willagrams/Shell/{HostLobby,Results,Countdown,SoloSetup}View.swift` contains a hard-coded screen-margin `.padding(` value; a grep confirms it, and each uses `.screenPadding()` or a token
    - HostLobby's code font and button height read from a compact-aware value. A ShellTests case on whatever plain struct or function supplies them asserts the compact value is smaller than the regular one
    - `xcodebuild` BUILD SUCCEEDED; the run summary names HostLobby/Results/Countdown/SoloSetup at iPhone landscape as Nate's hand test
  ui: true
  parallel-group: b
  status: not started

- task: Make the HUD bag legible on a phone. In `Willagrams/Shell/MatchHUD.swift` the bag is `bagSize` 96 (~line 118) at every size. At compact height use ~72, and render the count with `.monospacedDigit()` and a `.minimumScaleFactor` so three digits never truncate or wrap. The size choice lives in a testable value, not an inline literal.
  guardrails:
    - The HUD's layout at regular size class is unchanged
    - The count shows `—` exactly when `poolRemaining` is nil. It never shows a placeholder number
  done when:
    - A ShellTests case asserts the compact bag size is smaller than the regular one, and that the displayed text for counts 0, 9, 98 and 144 is the plain number, with nil shown as `—`
    - `xcodebuild` BUILD SUCCEEDED
  ui: true
  parallel-group: b
  status: not started

- task: Keep the field being typed in visible above the keyboard on every typing screen: `Willagrams/Account/ProfileView.swift` (display name), `Willagrams/Friends/FriendsView.swift` (add by friend code), and `Willagrams/Shell/JoinView.swift` (invite code). Each field gets a `@FocusState`; its scroll content is wrapped in `ScrollViewReader`, and on focus it calls `scrollTo(fieldID, anchor: .center)`; each scroll view gets `.scrollDismissesKeyboard(.interactively)`. On JoinView the Join button moves beside the field, so the action stays on screen while the keyboard is up. Tighter margins from item 1 are part of the fix: the hand test found the field hidden behind huge margins plus the keyboard.
  guardrails:
    - Uses SwiftUI's own keyboard avoidance plus `scrollTo`. No keyboard-height notifications, and no manual offsets
    - The iPad appearance of these screens does not change beyond item 1's sizing
  done when:
    - Each of the three views declares a `@FocusState`, scrolls the focused field into view on focus change, and sets `.scrollDismissesKeyboard(.interactively)`; a grep confirms all three
    - JoinView's Join button sits in the same row as the code field
    - `xcodebuild` BUILD SUCCEEDED; the run summary names "type into Profile name, Friends add-by-code and Join code on the iPhone in landscape — the field and its button stay visible" as Nate's hand test
  ui: true
  status: not started

- task: Make the validation messages reachable. Today each button is disabled by the same rule that would produce the message, so the message never shows: `ProfileModel.canSave` (~line 111, "A name is 1 to 24 characters."), `FriendsModel.canLookup` (~line 346, "A friend code is 8 characters."), `JoinModel.canJoin` (~line 132, "Enter the six-character code."). Disable each button only when the field is empty (after trimming) or a request is in flight. The action itself refuses bad input by setting the existing message and making no backend call. Add `.onSubmit` on the Profile and Friends fields so Return triggers the same action.
  guardrails:
    - Invalid input never reaches the backend. The refusal happens in the model before any call
    - The message text is the existing string, unchanged
  done when:
    - An AccountTests case: with a 25-character name, `canSave` is true, and `save()` sets the name-length message with zero writes recorded by the backend double
    - A FriendsTests case: a 7-character code leaves `canLookup` true, and lookup sets "A friend code is 8 characters." with zero backend calls. A ShellTests case: a 5-character join code leaves `canJoin` true, and join sets "Enter the six-character code." with zero backend calls
    - Each case fails if the model's own length check is deleted (mutation-checked), and an empty field still disables its button
    - Existing passing tests remain passing
  status: not started

- task: Unfriend. Add a `FriendForgetting` side protocol in `Willagrams/Online/`, following `FriendRequestForgetting.swift` exactly, so `BackendContracts.swift` does not move. Its one call deletes the friendship between the caller and a friend **filtered to `status = accepted`**. Implement it on `SupabaseBackend` (`SupabaseBackend+Friends.swift`) and on `FakeBackend`. `FriendsModel.unfriend(_:)` calls it through the existing `perform(failure:)` path and removes the row from the list on success. `FriendsView` gets an Unfriend button on each accepted friend's row, beside Block, behind a `.confirmationDialog`. The RLS policy `friendships_delete_own` (0001_init.sql:189) already allows the delete, so no migration is needed. Row buttons use item 1's compact sizing.
  guardrails:
    - Never deletes a pending or blocked row. A block must survive any unfriend call from either end
    - No change to `BackendContracts.swift` or `supabase/migrations/**`
    - A failed delete leaves the friend in the list and shows the model's existing failure message
  done when:
    - A FriendsTests case: after `unfriend` on an accepted friend, the FakeBackend holds no row for the pair and the list no longer shows them. A second case, unfriending a pair whose row is `blocked`, leaves that row in place; it fails if the `status = accepted` filter is removed (mutation-checked)
    - A gated live OnlineTests case, run with `WILLAGRAMS_LIVE_TESTS=1` and the key from `.env`, deletes an accepted friendship on `ynkayuwwrifluhhqnrjc` and confirms a blocked row between the same two test players is still there. The run summary quotes the live result
    - `xcodebuild` BUILD SUCCEEDED; the confirm dialog is named as Nate's hand test
  caution: true
  ui: true
  status: not started

- task: Let the board zoom further out. In `Willagrams/Board/BoardCamera.swift`, `minCellSize` goes from 24 to 16 (~line 17), and every clamp that reads it follows. This is also what lets recenter fit a large board (item 9).
  guardrails:
    - `maxCellSize` and the pinch behavior at the top of the range are unchanged
  done when:
    - A BoardTests case pinches out from the default zoom and settles at a cell size of 16, not 24
    - Existing BoardTests remain passing, with any assertion that hard-coded 24 as the floor updated to the new floor
  parallel-group: c
  status: not started

- task: Remove drag snap-back. A tile released anywhere stays where it was dropped unless the target cell is occupied. Today a fast drag snaps the tile back to its origin. **Reproduce before fixing.** The distance guard in `TileDrag.landing` (`Willagrams/Board/BoardDrag.swift` ~line 201) looks nearly dead at threshold 96, so the real cause is unproven. Suspects to rule in or out, in order:
    - a stray second touch reaching `cancel()` through `BoardPinchReporter`
    - a mid-drag `sync()` write resetting the dragged tile
    - a system edge gesture (`.defersSystemGestures`) swallowing `onEnded`, so the drag ends through the cancel path
  Fix the cause you prove. Delete the distance guard: "too far" is no longer a reason to refuse. A drag that ends through a cancel path lands at its last reported location, under the same occupied-cell rule.
  guardrails:
    - A drop onto an occupied cell still returns the tile to its origin, with the existing invalid feedback
    - Multi-tile group drag keeps its current all-or-nothing rule: the group lands only if every target cell is free
    - No change to how a drag *starts* (hit-testing, long-press, pan disambiguation)
  done when:
    - The item report names the proven cause, with the test or trace that reproduced it before the fix
    - A BoardTests case drags a tile across 20+ cells in a single large-translation update and releases it on an empty cell: the tile lands there. Released on an occupied cell, it returns to its origin
    - A BoardTests case ends a drag through the cancel/interrupted path after a move: the tile lands at the last reported cell, not its origin
    - Each new case fails with the old guard restored (mutation-checked); existing BoardTests remain passing
  caution: true
  ui: true
  parallel-group: c
  status: not started

- task: Make recenter actually frame every tile. `BoardView` gains `chromeInsets: EdgeInsets` (the HUD's footprint). `Willagrams/Shell/MatchView.swift` passes the HUD's real insets, and solo and online both go through it. Recenter frames the occupied bounds inside the view rect *minus* those insets, through `BoardLayout.framing`. Wire it at both recenter call sites: the recenter control (~BoardView line 412) and the `.task(id: board)` initial framing (~line 239). With item 7's floor, a board too big to fit at 16pt clamps to 16 and centers on the occupied bounds.
  guardrails:
    - `BoardView`'s init keeps compiling for every existing caller. `chromeInsets` defaults to zero
    - Recenter never zooms *in* past the default cell size on a small board
  done when:
    - A BoardTests case: `BoardLayout.framing` for a 20-column by 12-row spread, in an 812×375 view with the iPhone HUD insets, returns a camera where every occupied cell's rect lies inside the inset rect
    - A BoardTests case: a spread wider than 16pt cells can fit comes back at cell size 16, centered on the occupied bounds' midpoint
    - `xcodebuild` BUILD SUCCEEDED
  status: not started

- task: Stop tiles already on the board from re-animating when panned back into view. `BoardSurface` culls to `visibleCoords`, so a pan changes the rendered id set, and the `FromBag` insertion transition (BoardView ~lines 561–578) fires on tiles that were always there. Apply `FromBag` only to ids in `arriving` (tiles that are actually new), and key the animation on `arrivalToken`, not the visible set. Pull the transition choice into a plain function BoardTests can call.
  guardrails:
    - A freshly drawn or dealt tile still flies in from the bag exactly as today
    - Culling stays. Rendering every tile is not the fix
  done when:
    - A BoardTests case: the transition function returns the bag transition for an id in `arriving` and the identity/none transition for an id that only entered `visibleCoords`. It fails if the `arriving` check is removed (mutation-checked)
    - `xcodebuild` BUILD SUCCEEDED; "pan a tile off screen and back — it does not fly in" is named as Nate's hand test
  ui: true
  status: not started

- task: Land drawn tiles next to the player's connected board. Two causes, both fixed here. First, `MatchBoard.camera` (`Willagrams/Shell/MatchBoard.swift` ~line 96) is never updated from BoardView's live camera, so delivery places tiles for a stale viewport; wire BoardView's `onCameraSettled` to set it. Second, `BoardLayout.delivered` (~lines 51–87) anchors at the viewport's left edge under the Draw buttons. Make it anchor on the empty cells nearest the largest connected cluster (directly below it first, then beside it), clamped inside the inset view rect from item 9 when the cluster is on screen.
  guardrails:
    - Delivered cells are always empty and never overlap each other or a placed tile
    - When the board is empty (the opening deal), delivery keeps today's layout
    - Draw's gate (one connected cluster, no invalid words, empty hand) is untouched
  done when:
    - A BoardTests case: with a cluster at rows 10–12, cols 30–35 and a camera looking elsewhere, `delivered` returns empty cells within two rows below the cluster's bounding box, none overlapping
    - A ShellTests case: after BoardView reports a settled camera, `MatchBoard.camera` equals it, and the next Draw delivers inside that camera's inset rect
    - Each case fails with its fix reverted (mutation-checked); existing BoardTests and ShellTests remain passing
  caution: true
  status: not started

- task: Fix the early start. Only the lobby creator's Start button opens an online match. Root cause: `OnlineMatch.awaitStart()` (`Willagrams/Online/OnlineMatch.swift` ~line 387) calls `open(session)` on the joiner when `HostPool.host(of: roster)` names it. That is the gameplay host, the lowest id, not `matches.host_id`. So a joiner with a lower id started the match itself, the creator became a guest, and its bag showed no count. Change: `awaitStart()` never opens; the creator's `start()` always opens; `MatchSession.startMatch`'s guard (~line 644) becomes `roster.contains(localPlayerID)`, so the creator may send `.start` even when it is not the pool host. The pool host is still `roster[0]` and still deals on `applyStart`. Rewrite the tests that pinned the old rule (`MatchSessionHardeningTests` ~line 693, `SoloMatchTests` ~line 100) to the new one, rather than deleting them.
  guardrails:
    - The pool authority stays `roster[0]` on every device. Only who may *send* `.start` changes
    - A second `.start` is still ignored (`applyStart`'s `hasStarted` guard)
    - Solo practice still starts itself with no Start press from a remote player
  done when:
    - An OnlineTests case where the joiner has the lower id: after `awaitStart()` returns, the joiner's session is still waiting, and it opens only after the creator calls `start()`. It fails with the old auto-open restored (mutation-checked)
    - In that same case, after the start, the lower-id device holds the pool (`poolRemaining` non-nil there) and both devices' racks hold the opening deal
    - MatchTests, OnlineTests, ShellTests and BotTests are green at or above their floors
  caution: true
  parallel-group: d
  status: not started

- task: Show the pool count on the guest. `HostPool` broadcasts `.poolCount(remaining: pool.count)` after the opening deal, after every draw round, and after every swap. It goes out with `.reliable` delivery through the same `answer` path, to peers only. The guest's `MatchSession.receive` handles `.poolCount` by writing through `setPoolRemaining`, reusing `storedPoolRemaining`; add no new observed property. The receive guard: ignore it on a device that runs the pool; drop `remaining < 0` or `> MatchLimits.poolSize`; keep the minimum of the current and received counts, since the pool never grows and Realtime can reorder. Update `poolRemaining`'s doc comment: a guest now knows the number.
  guardrails:
    - Informational only. The guest never draws, swaps or latches exhaustion from this count; `poolExhausted` still does that
    - No observed stored property is added to `MatchSession` (toolchain limit); MatchTests must run
    - The host never shows the peer's count over its own pool's
  done when:
    - A MatchTests case, host and guest over `FakeTransport`: after the opening deal, a draw round and a guest swap, `guest.poolRemaining == host.poolRemaining` at each step
    - A MatchTests case: a guest receiving 90, then a late 95, shows 90; receiving -1 or 145 changes nothing; a host receiving `.poolCount` keeps its own count. Each guard is mutation-checked
    - MatchTests, ShellTests and OnlineTests are green at or above their floors, after `swift package clean` on each
  caution: true
  status: not started

- task: WILLA is a valid word, with a small hidden flourish. Add an app-layer `WillaWordList` in `Willagrams/Match/` that wraps any `WordList`, accepts "WILLA" (matching the base's case convention), and defers everything else. Its hash is the **base's** hash, so the start's dictionary-hash gate still matches between devices. Wrap the dictionary once where it is built, at `ShellModel.swift` ~line 129 and next to the `MinimumLengthWordList` wrap in `MatchSession.applyStart` (~line 990), so the board, the Draw gate and the win check all see it. Add `BoardModel.willaRuns`: the coords of every horizontal or vertical run spelling WILLA. When it becomes non-empty, `BoardView` tints those tiles with the accent color and plays a one-shot sparkle, once per new run, using DesignTokens motion values.
  guardrails:
    - `Sources/WillagramsRules/**` and `dictionary.txt` are not touched; the word lives only in the wrapper
    - The canonical dictionary hash is unchanged. Two devices still agree, and a v4 start still validates
    - The sparkle never replays on a pan or on an unrelated board change; it fires once per new WILLA run
  done when:
    - A MatchTests case: `WillaWordList(base)` accepts WILLA, rejects WILAL, defers other words to the base, and reports the same hash as the base
    - A BoardTests case: `willaRuns` returns exactly the 5 coords of a horizontal WILLA and of a vertical one, and is empty for a board without it
    - A ShellTests case: a board whose only non-dictionary word is WILLA passes the Draw gate in solo practice
    - `xcodebuild` BUILD SUCCEEDED; "spell WILLA — tint and sparkle once" is named as Nate's hand test
  ui: true
  status: not started
