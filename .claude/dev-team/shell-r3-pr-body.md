# shell round 3 — every screen reachable, against the live backend

Round 3 of the `shell` lane, under the MAP grant of 2026-09-03 that folded the
`account` and `friends` areas into it. Run paused after item 1 at the user's
request; items 2–12 are unbuilt.

Items done: 1 of 12. Items blocked: none.

## Harvested team-memory entries

`/merge-lane` appends these to `.claude/dev-team/team-memory.md` in merge order.

## 2026-09-04 15:12 — dev-team-auto — shell r3 item 1: build the app's services once, at the root, and inject them
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, medium) — auto/shell-r3, 6efd2c609bbadee5a5e79c7b763dd7ad3af716d8
- **What happened:** `ShellServices` (plain struct: optional `BackendClient`, `AudioPlayer`, optional `SettingsStore`, optional `ShellSignIn`) declared in `Willagrams/Shell/`, built once in `WillagramsApp.init()` and passed to a new `services:` parameter on `ShellModel.init`. `ShellModel` owns a `signInTask` cancelled in `deinit`, publishes `currentProfile` and `onlineUnavailableReason`, and never awaits sign-in on the launch path. `ShellSignInSupabase.swift` holds the only `#if DEBUG` in Shell.
- **What worked:** ShellTests grew Online/Audio/Settings WITHOUT adding supabase-swift — the two SDK-free Online files (`BackendContracts.swift`, `FakeBackend.swift`) were added as extra `sources:` of the existing `Match` target (the app compiles Match+Online into one module, so those files carry no `import Match`), and `Audio` excludes `SystemAudioPlayer.swift` (AVFoundation/UIKit), `Settings` excludes both files under `Views/`. ShellTests still runs in ~7s. The two source-scan fence tests are deliberately falsifiable: each asserts the symbols it greps are present somewhere, so a rename turns them red instead of vacuously green — respelling `"SupabaseBackend("`/`"SystemAudioPlayer("` in the scan made `onlyTheRootBuildsServices` go red on exactly that assert. Release fence proved independently by `nm` on the Release binary: all six `signInAnonymously` symbols are `4Auth…` (the SDK's own), zero from the `10Willagrams` module, and no `SupabaseBackend: ShellSignIn` witness table.
- **What failed:** Four existing ShellTests (`ResultsModelTests`, `SoloSetupTests`, `ShellModelTests`, `ShellRootViewTests`) built a `ShellModel` with the real wall-clock `sleepFor` and started a countdown that outlived the test; adding a service to `ShellModel` surfaced it as a hard process abort (signal 6, `swift_task_dealloc`) when `MatchSession.deinit` cancelled the leaked sleep. Fixed by injecting `sleepFor: { _ in }` — construction only, no assertion weakened. This was latent before this item, not caused by it.
- **Remember next run:** (1) `ShellServices` is the injection seam for every later shell item — read `services.backend` / `services.audio` / `services.settings`; never construct one, `ServiceFenceTests.onlyTheRootBuildsServices` scans all of `Willagrams/` and only `WillagramsApp.swift` is exempt. (2) Any new ShellTests case that builds a `ShellModel` and touches a route MUST pass `sleepFor: { _ in }` or the whole test process can abort. (3) `ShellSignInSupabase.swift` is fenced `#if canImport(Auth)` as well as `#if DEBUG`, so ShellTests compiles it empty — the `SupabaseBackend: ShellSignIn` conformance is only compile-checked by `xcodebuild`, so run xcodebuild after touching it. (4) `Tests/ShellTests` deliberately has NO supabase-swift dependency; keep it that way — anything needing the real client belongs in `Tests/OnlineTests`. (5) `nm <Release binary> | grep <symbol> | xcrun swift-demangle` is the cheap, real proof of a Release fence; a source grep alone is not.

## Run-level notes (top-level orchestrator, 2026-09-04)

- Baseline measured on this branch before item 1: root 53, BoardTests 253 (XCTest), MatchTests 125, StyleTests 30, ShellTests 120, SettingsTests 36, OnlineTests 126 (1 `withKnownIssue`), AudioTests 19, BotTests 68 (~202s), iOS `xcodebuild` BUILD SUCCEEDED. **Zero pre-existing failures.**
- **LANE.md's Global rules and README.md both say ShellTests is 125. It is 120.** `@Test` counts are identical on `main`, `integration` and the lane branch, so nothing was lost in a merge — the 125 is stale bookkeeping. Fix it in LANE.md/README rather than hunting five missing tests. (Post-item-1 it is 131.)
- `integration` was ahead of `lane/shell-r3` by the nine sound-effect `.wav` assets only; merged in at `8d92a49` before item 1. **LANE.md's "Out of scope — Sound asset files — none exist in the bundle" is now false**: item 11's cues will be audible, not silent no-ops.
- Items 7, 8 and 9 all carry `parallel-group: a`, but item 9 extends item 8's `FriendsModel` and reuses item 7's `ProfileView` — it cannot build before them. Planned dispatch is 7 ∥ 8, then 9 sequentially. Fix the marker in LANE.md before the next run.

### Item 2 — Let `MatchRun` run a match it did not build (`d116ced`, 1 attempt, engineer-only)

- **Inject the opponent as a closure, not a value.** `ShellModel.startMatch(_:opponent: @MainActor () -> any MatchOpponent)` takes a *builder*. A built value would be constructed before the call is entered, which makes down-before-up teardown unenforceable. With the closure, `startMatch` leaves the previous opponent first and only then calls the builder — and a test can prove the ordering.
- **A recording test-double is the only check that sees teardown *ordering*.** A double logging `build` / `leave` into a shared array caught it; the weak-reference alive-count check in `RematchTests` cannot — it only proves how many live, never in what order they died.
- **Keeping `MatchRun.match` as `public private(set) var match: SoloMatch!`** let `RematchTests`, `MatchRunTests`, `SoloMatchTests`, `SoloSetupTests` and `ShellModelTests` pass with **zero** edits. The split was a designated opponent-taking init plus a solo convenience init, so the solo call sites never changed.
- **Caveat for items 3 and 5:** `MatchRun.match` is set only by the solo init — reading it on an online run traps by design. Route through `run.opponent` / `run.session` only. Nothing in `Willagrams/` currently reads it.
- **Fast loop:** ShellTests runs in ~10s; `--filter MatchOpponentTests` is ~1s.
- **Counts:** ShellTests 131→135, root 53, MatchTests 125, `xcodebuild` BUILD SUCCEEDED.
- **Mutation checks (4, all restored byte-identical, tree verified against `d116ced`):** opponent built before `returnToMenu()` → the ordering test went red; `leave()` dropped from `endSoloPractice` → 13 named cases across `QAMatchRunTests`/`RematchTests`/`MatchRunTests` went red on `session.isMatchOver` (liveness is genuinely observed); `opponent.leave()` → `(opponent as? SoloMatch)?.leave()` → the source scan went red on both its presence assertion and its cast fence; `MatchRun.start()` no-op → the countdown→match→results walk went red.

### Item 3 — Host a match from the menu and show the invite code (`07ab41b` + `2790d07`, 1 attempt, engineer-only)

- **An ordering guardrail between two synchronous statements is invisible to any test that inspects state after the call returns.** "Tear the lobby down before the route moves" survived a mutation that reordered it — both halves land in one main-actor turn, so nothing after `cancel()` can see the intermediate state. Pinned with a `withObservationTracking` observer on `route` whose `onChange` fires on `willSet` and asserts the channel is already gone; the mutation then went red. **Items 4 and 10 have the same shape — use the same technique.**
- **`FakeTransport.pair` makes "waits for a second player" vacuously green** — it buffers a `.connected` on both endpoints before returning. The builder used a `LobbyWire` double instead, with falsifiability designed into the double rather than asserted afterwards.
- **Reversing `OnlineMatch`'s roster is caught only as a hard precondition abort** in `MatchSession.swift:428`, not a clean assertion — host election is enforced upstream of the shell, so shell tests cannot assert on it cleanly.
- **Criterion 4 (live, two simulators) is unverified and was not weakened.** Nothing in `Willagrams/` calls `OnlineMatch.join`, so a second simulator has no in-app path into the host's lobby. Item 3's criterion 4 and item 4's criterion 4 are the same run — do them once, together, after item 4.
- **Open risk, not gating:** `OnlineMatch.leave()` fires the abandon as a detached `Task` with `try?`. A failed abandon is silent and the row stays `lobby`; `abandon(matchID:)` cannot report that it matched zero rows.
- **Counts:** ShellTests 135→142, root 53, MatchTests 125, OnlineTests 126 (+1 pre-existing known issue), xcodebuild BUILD SUCCEEDED. 7 mutation checks, all restored byte-identical.

### Item 4 — Join a match by invite code (`b66aafe` + `4c874d1`, 1 attempt, engineer-only)

- **A test that exercises a pure mapping function is not coverage of the screen that calls it.** The error-copy test asserted only `HostLobbyModel.message(for:)` as a pure function and never drove `JoinModel` — so a probe that swallowed every non-`.notFound` error stayed green. Closed with a parameterized model-level test over `.matchFull` / `.permissionDenied` / `.offline` driven through a `RefusingJoin` decorator; the mutation then went red on all three arguments.
- **9 mutation checks all went red**, covering every `done when:` criterion and all three guardrails, including the orphan-task and cancel-before-route ordering pair (using item 3's `withObservationTracking` technique) and the `JoinView` `exclude:` source fence.
- **Live, two simulators — both deferred criteria MET.** Host on iPhone 17 Pro showed invite code `M24Z8A`; after the guest joined on iPhone 17 Pro Max the host roster named both players; the guest reached `Waiting for host: …` and both devices reached the match screen when the host pressed Start. This closes **item 3's criterion 4** as well as item 4's. The anon key was sourced from the gitignored `.env` only and reached no source, test, fixture or log.
- **Counts:** ShellTests 142→153, root 53, MatchTests 125, OnlineTests 126 (+1 pre-existing known issue), xcodebuild BUILD SUCCEEDED.

**Four findings the live run surfaced — no code changed, carried for later items and the lane review:**
1. **`OnlineMatch.awaitStart()` returns as soon as `match_players` has two rows** and opens the match itself when the guest sorts as `roster[0]` — which makes the host's Start a no-op in roughly half of pairings. This is an Online-lane issue, not shell's, and **item 10 will hit it.**
2. `JoinView`'s `TextField` transiently renders characters the sanitiser rejects (a typed `-` showed as `M24Z-`). SwiftUI does not re-sync the field when `didSet` normalises to a value equal to the last observed one. The *model* clamp held — the live join used exactly `M24Z8A` — so the guardrail is intact; display-only, one-line polish fix.
3. `HostLobbyModel.message(for: .permissionDenied)` reads "You can't host a match right now." — host-voiced copy now shown on the guest's join screen. Reusing that mapping was mandated by item 4's prompt, so it was left as-is.
4. The Join button renders at full primary strength while `disabled(!canJoin)` — no disabled affordance.

### Item 5 — Reconnecting overlay, end on gone, online results home (`d68bc41` + `dc03b70`, 1 attempt, engineer-only)

- **`MatchHUDModel` is fenced against `peerPlayerID`** by `MatchHUDTests.hudNamesNoOpponent`. The item's literal wording ("the match-side model") pointed there, but putting the overlay on `MatchBoard` instead satisfied it without editing an existing assertion. **Put peer-identity work on `MatchBoard`, not the HUD.**
- **A protocol requirement with a default beat both a stored flag and an `is OnlineOpponent` cast.** `MatchOpponent.offersRematch: Bool` (default `true`, `false` on `OnlineOpponent`) lets `MatchRun.results()` omit the rematch closure while keeping item 2's fence that `MatchRun` never learns its concrete opponent type.
- **"No new stored state" guardrails are invisible to behaviour tests by construction.** Mirroring presence into a stored `MatchBoard.overlay` refreshed from `track()` passed all 159 tests — the "presence is read, never stored again in Shell" guardrail was unpinned. Closed with a falsifiable source-shape test asserting the *computed* spellings are present; the mutation then went red. This is the third run of the same lesson: a fence needs its own test that asserts what it greps is actually there.
- **A new overlay view inside an already-excluded View file needs no new `exclude:` entry** — `ReconnectingOverlay` landed inside `MatchView.swift`, already excluded. Check before adding one.
- The Swift 6.3.3 `MatchSession` toolchain limit was **not** tripped — MatchTests stayed at 125.
- **Counts:** ShellTests 153→160, root 53, MatchTests 125, OnlineTests 126 (+1 pre-existing known issue), xcodebuild BUILD SUCCEEDED. 9 mutation checks, all restored byte-identical.

**Contract for later items:**
```
MatchOpponent.offersRematch: Bool — default true; false from any far end that
  cannot be rebuilt from the end screen. MatchRun.results() omits the rematch
  closure when it is false.
MatchBoard.overlay: MatchOverlay? (.reconnecting(peer: String)),
MatchBoard.inputLocked: Bool, MatchBoard.reconnectingTitle
  — all computed off MatchSession; do not store presence.
ResultsModel.noWinnerHeadline == "Opponent left"
```
