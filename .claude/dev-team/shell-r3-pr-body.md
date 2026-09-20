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

### Item 6 — Present the settings lane's options view and persist the choice (`2fa2198` + `e4c64b7`, 1 attempt, engineer-only)

- **`#expect(x == x.transform())` is always a tautology when `x` is already the transformed value.** The pre-existing `#expect(setup.options == setup.options.validated)` looked like it pinned the `MatchOptions.validated` guardrail; deleting `.validated` from production left the suite green. Closed with a test driving `startSoloPractice(options:)` with `minimumWordLength: 99`. **Grep new and inherited assertions for both sides deriving from the same expression before trusting them.** Fourth consecutive item shipping with exactly one vacuous check.
- **A source fence needs a presence half as well as an absence half.** The fence asserts `MatchOptionsView(form:` really appears in `SoloSetupView.swift` alongside banning the four `MatchOptions` field names. Mutation 6 re-added a real banned `Toggle` to production and the fence caught it, proving it is not vacuous.
- **Scoping the fence to the four `MatchOptions` field names** (rather than "any Toggle/Stepper") keeps `startingHandSize` — which lives on `MatchSetup`, not `MatchOptions` — and item 12's mute toggle legal without weakening it. Note for a human: a `Stepper` therefore does remain under `Willagrams/Shell/**`, deliberately.
- **`MatchOptionsForm()` hashes the whole ENABLE word list** (~2.2 s in a debug macOS test build). Build it once per `SoloSetup` on screen entry, never at `ShellModel.init`, or every ShellTests case that constructs a model pays for it.
- **`Willagrams/Settings/**` was consumed, not edited** — verified independently: `git diff --stat` over `Willagrams/Settings` and `Tests/SettingsTests` is empty. SettingsTests 36 before and after.
- **Counts:** ShellTests 160→164, SettingsTests 36, root 53, MatchTests 125, xcodebuild BUILD SUCCEEDED. 7 mutation checks, all restored byte-identical.
- **Cosmetic, unfixed (Settings is consume-only):** `MatchOptionsView` ships its own `"HOST"` mono label, `"Match options"` title and full-bleed gradient canvas, which reads wrong embedded in a solo screen. A settings-lane or dt-ui item, not shell's.

**Contract for later items:**
```
SoloSetup(store: SettingsStore?) — optionsForm: MatchOptionsForm? (settable; nil
  until entry), loadOptions(), saveOptions(_:), options: MatchOptions (always
  .validated). Go through optionsForm, not the removed scalar properties.
ShellModel.soloSetup is a `let` assigned in init from services.settings.
HostLobbyTests.make(sleepFor:settings:) — new optional settings: SettingsStore? = nil.
```

### Item 7 — The profile screen (`20b3fe8` + `71a100c`, 1 attempt, engineer-only)

- **Any UIKit/AppKit-fenced injection is unobservable to `swift test` and needs a source-level assertion that the wiring exists.** Deleting `pasteboard: Self.pasteboard` from `ShellModel.showProfile()` left the whole suite green: `ProfileModel` fell back to its no-op default, so the app's Copy button would have silently copied nothing, invisibly on macOS where UIKit is absent. Closed with `ProfileRouteTests."The shell hands the screen a clipboard that really writes"`. The same trap waits for a share sheet or haptics. Fifth consecutive item shipping with exactly one vacuous check.
- **A new test package consumes `Willagrams/Online` file-by-file, not as a directory.** `AccountTests` symlinks `OnlineSrc -> ../../Willagrams/Online` but lists only `BackendContracts.swift`, `FakeBackend.swift`, `MatchOutcomeRecorder.swift` and `OnlineMatch.swift` as extra `sources:` of its `Match` target. That is ShellTests' approach, not OnlineTests' whole-directory one, and it keeps the Supabase SDK out: no `supabase-swift` dependency and no `Package.resolved` (verified — zero `supabase` references in the manifest). Copy this shape for `Tests/FriendsTests`.
- **A model that `ShellModel` constructs needs a mirror target in `Tests/ShellTests/Package.swift`** with the same source symlink and the same View `exclude:` — otherwise ShellTests stops building the moment the shell references it.
- **No stat is computed client-side.** `ProfileModel.stats` is exactly four `ProfileStat`s read off the row as returned, so a server-side scoring change needs no app change.
- **Counts:** ShellTests 164→173, AccountTests 15 (new), root 53, xcodebuild BUILD SUCCEEDED. 12 mutation checks, all restored byte-identical.

**Contract for later items:**
```
AppRoute.profile · ShellModel.profile: ProfileModel? · @discardableResult showProfile() -> Bool
  (guards case .menu + non-nil currentProfile; torn down in returnToMenu() before the route moves)
ProfileModel(profile:isEditable:backend:pasteboard:) — draftName, trimmedDraft, canSave,
  message, isSaving, didCopyCode, stats: [ProfileStat] (exactly 4), save() async,
  copyFriendCode(), shareMessage, static nameLength = 1...24.
Item 9 reuses it read-only: ProfileModel(profile: friend, isEditable: false).
ProfileView(model:) takes its onward action as a closure — the view holds no route.
```

### Item 8 — The friends list (`b80db6a` + `f0f1f9a` + `1b3737f`, 4 attempts, **`caution: true`** — full engineer + QA + review team)

QA VERDICT **PASS** at attempt 3 (mutation-tested, no surviving mutant, live gate confirmed load-bearing). Re-review closed all five prior Important findings and raised one new Important — a missing `generation == mine` check on the `friendships()` catch branch — fixed in `1b3737f` and pinned with a mutation-RED regression case. Final review: 0 Critical, 0 open Important, 6 Minor.

- **A live-gated RLS test proves nothing unless you also run the gate-off control.** RLS refuses by returning zero rows, never an error, so a fake-only pass and a real pass look identical. QA confirmed the gate was load-bearing by checking that gate-off skips exactly the four live cases. Verified independently at the merge commit: gate on, 29 tests in 1.93 s; gate off, the same 29 pass in 0.019 s with those four skipped.
- **Three separate vacuously-green tests shipped in this item before mutation testing caught them.** (1) A `sorted(by:)` was deletable because the fake returned rows already in name order — fixed by renaming a fixture friend so row order and name order disagree. (2) A guardrail scanning the whole of `MenuView.swift` for `.disabled(...)` was already satisfied by a pre-existing row — fixed by bounding the scan to the Friends row and asserting the scoping held. (3) A spinner assertion armed only the write gate and so never observed the write→reload seam. **Grepping a whole file for a string is not a guardrail; scope the scan and assert the scope.**
- **`.timeLimit` cannot interrupt a parked `withCheckedContinuation`** — a swift-testing case that waits on a gate hangs forever rather than failing. Bound it with an arrival-count poll and a ceiling.
- **`withObservationTracking` re-armed inside its own `onChange` fires in `willSet`**, which is the only way to pin an ordering guardrail between two synchronous statements. It was the sole killer of the `end(); await load(); begin()` mutant.
- **A stale-publish guard applied to the success path and not the failure path is a live bug**: the losing load's error message overwrites the winner's sections. Guard every branch that publishes, including `catch`.
- **`Tests/FriendsTests` had to diverge from the `Tests/AccountTests` layout**: the live cases need `SupabaseBackend.signInAnonymously()` and therefore the Supabase SDK, so it follows OnlineTests' declaration (and does carry a `Package.resolved`) while keeping the module named `Match` so `#if canImport(Match)` still resolves.
- **Correction to an earlier note:** `ProfileView` does *not* call a `showFriends()` closure — it takes only `onBack`. Friends is reachable from the menu only.
- **Counts:** FriendsTests 29/5 (new, live), ShellTests 173→182, AccountTests 15, OnlineTests 126, root 53, xcodebuild BUILD SUCCEEDED. Anon key absent from every commit; `supabase/**` byte-identical to `6c49764`.

**AMENDMENT REQUEST (reported, not fixed — `supabase/migrations/**` is protected):** `respondToFriendRequest(accept: false)` sets `status = blocked` in both `FakeBackend` and `rls_behavior.sql`, and no seam call unblocks. **Declining a request therefore permanently blocks the person.** This needs either an unblock seam call or a `declined` status distinct from `blocked`, via `/foundation`.

**Two caveats for a human:** `profilesAreReadTogether` polls `Gate.arrivalCount` with a 2 s ceiling — the one timing-dependent case in the suite. And the profile cache never expires within a screen visit, so a name changed elsewhere mid-visit shows stale; bounded, because `ShellModel` builds and tears down a `FriendsModel` per visit.

**Contract for later items:**
```
AppRoute.friends · ShellModel.friends: FriendsModel? · showFriends() — menu action
  "Friends", enabled when currentProfile != nil; torn down in returnToMenu()
  before the route moves.
FriendsModel publishes three sections (accepted / incoming pending / outgoing
  pending), resolves each counterpart through profile(id:), and writes only
  through respondToFriendRequest(requesterID:accept:) and block(_:) — no
  client-side status arithmetic. Blocked players are hidden from every section.
FriendsView holds no route; onward actions are closures. Item 9 adds lookup by
  code and opens ProfileModel(profile:isEditable: false) from a row.
```

### Item 9 — Add a friend by code, and open a friend's profile (`08e3490`, 1 attempt, engineer-only + 7 orchestrator mutation checks)

**The first item in this lane where no check stayed green under mutation** — 7 independent orchestrator mutations on top of the engineer's 14, all caught, all restored byte-identical per `diff -q`. Two of the three `done when:` criteria were refusals ("cannot request themself", "makes no backend call"), which look identical to a clean run once they stop firing, so a green suite alone would have proved nothing about them.

- **The pattern that made the refusals provable: every "refuses / makes no call" assertion is paired with a positive test asserting the same recorder is non-empty**, so the recorder itself cannot silently stop recording. Mutation MY-3 neutered `GatedBackend.friendCodeLookups.append` and turned the positive cases red, which is what proves the `.isEmpty` no-call assertions are load-bearing rather than vacuous.
- **`FriendsModel.init` takes the whole `Profile`, not `me: UUID`.** The own-code refusal is impossible without the code client-side; 21 test call sites was the cheap price.
- **Scoping a source fence to one `@ViewBuilder private var` body** via a `body(of:in:)` helper, with `#require` on the property being found, caught both a wiring change (MY-6) and a rename (MY-7). This is the corrected form of item 8's whole-file grep.
- **`ProfileView` reused unchanged**, no new View file, so no `exclude:` change. Back-destination is carried by a private `profileReturn: AppRoute` on `ShellModel` plus `dismissProfile()`, not by the view.
- **`ProfileRouteTests.rootRendersTheScreen` legitimately went red** because it asserted the old `returnToMenu()` wiring; it was updated to `dismissProfile()` rather than weakened.
- **Counts:** ShellTests 182→188, FriendsTests 29→41 (live gate on), AccountTests 15, root 53, xcodebuild BUILD SUCCEEDED. Verified independently at the merge commit. One ShellTests run failed with a single issue and three subsequent runs passed at 188 — consistent with the wall-clock flakiness this file already documents for the countdown overlay case, not a regression from this item.
- **Bookkeeping note:** the agent committed its team-memory entry to `.claude/dev-team/team-memory.md` (`da55379`). Lane mode forbids that on a lane branch — `/merge-lane` appends from this PR body in merge order, and a shared file written per-lane conflicts on every merge. Reverted in `2cafdb6`; the entry lives here instead.

**Still open, deliberately not fixed here (both belong elsewhere):**
- `respondToFriendRequest(accept: false)` still sets `blocked` with no unblock seam call, so **a declined player can never be re-added by code.** The `.blocked` copy is an honest dead end until the filed `/foundation` amendment lands.
- **A read-only profile still offers Copy/Share of the *friend's* friend code**, because `ProfileView` gates copy on nothing but the button existing. That fix belongs in `Willagrams/Account`, not the shell.

### Item 10 — Invite a friend to play, in-app (`0c30d05` → `915e14a` → `77b6ae6` → `7894b1e`, 3 attempts, **`caution: true`** — full engineer + QA + review team)

QA VERDICT **PASS** at attempt 3, gate mode `tests+behavioral`. Review ran three times and ended **0 Critical / 0 Important**. Attempt 1 passed QA but review found 4 Important; attempt 2 closed those and introduced 2 new ones; attempt 3 closed those. **A fix pass is a new diff and needs a real re-review, not a rubber stamp** — that is what caught the second round.

- **A recipient-side trust check is where the real security lives on a broadcast feature.** The "only accepted friends can invite you" guardrail was enforced only on the *sender's* client until review caught it; a sender's client is not a trust boundary. It is now checked on receipt.
- **QA disproved the engineer's own mutation claim.** The engineer reported the `.accepted` half of the sender check as covered; QA re-derived it and showed the stranger test *structurally cannot* isolate the status predicate, because a stranger has no friendship row at all. QA added the missing pending-sender test. **Making QA re-derive rather than accept engineer mutation claims is what earned this item its coverage.**
- **The clock is injected.** `sentAt` staleness uses an injected `now`/`sleepFor`, never a real clock, so the two-minute expiry case is deterministic.
- **Telling the engineer up front that `Tests/ShellTests/Package.swift` lists Online files by name** decided the whole file layout at zero rediscovery cost: `MatchInvite` + an SDK-free channel protocol + `FakeInviteBus` in one file listed by name, and `SupabaseMatchInviteChannel` (Realtime) in a second file only the whole-directory packages compile.
- **Counts (verified independently at `7894b1e`):** ShellTests 188→**207**, OnlineTests 126→**132** (offline and live), FriendsTests 41→**43** live, AccountTests 15, root 53, xcodebuild BUILD SUCCEEDED. `supabase/migrations/**`, `BackendContracts.swift` and `team-memory.md` all untouched, confirmed by name in the diff. No key in any commit.

**⚠️ Criterion 4 is UNRUN, not met.** "Live, on two simulators: A taps Invite, B's banner appears, B joins, A starts, both reach the match screen" **was not executed.** This repo has no XCUITest target and `simctl` has no tap primitive, so no agent here can tap a button on a simulator. What *is* live-proven is the transport half: `MatchInviteChannelLiveTests` runs two real users against the live project and delivers an invite in ~1.1 s against the 5 s budget. **A's real tap, B's banner on device, and both reaching the match screen remain unverified and are a manual check a human owes before ship.**

This also casts doubt on how items 3 and 4 recorded their own two-simulator criteria. Those were reported as live-proven end to end, and the transport work plainly was; whether the on-device tap-through was ever actually performed is not something this run can now confirm. **Recorded as an open question rather than resolved in either direction.** The durable fix is either an XCUITest target, or writing such criteria as "a live transport test plus a named manual check" instead of as something an agent can claim.

**⚠️ SECURITY — needs a `/foundation` amendment, could not be fixed here.** Supabase Realtime broadcast channels are **public by default**. Invite topics are named for the recipient's user id, so anyone who resolves a friend code to a UUID can subscribe with the shipped anon key and read live `inviteCode`s — and join that lobby ahead of the invited friend. Spoofing is shut by the new recipient-side check; **eavesdropping is not.** The real fix is `config.isPrivate` **plus** a `realtime.messages` policy — `isPrivate` alone breaks the channel outright — and that policy is a migration, which this item's own guardrail forbids. **Any lane item that forbids migrations cannot fully secure a broadcast topic; the migration has to be planned in the same round.**

**Contract for later items:**
```
MatchInvite(matchID, inviteCode, hostID, hostName, sentAt) + an SDK-free channel
  protocol + FakeInviteBus — one file, listed by name in Tests/ShellTests/Package.swift.
SupabaseMatchInviteChannel — Realtime; only whole-directory packages compile it.
ShellModel — an invite pump, a banner with injected now/sleepFor, and a
  recipient-side accepted-friend gate. At most one banner per matchID.
Invite code is 6 chars; the friend code is 8. Do not conflate them.
```

### Item 11 — give every sound cue a call site

**A default value on an injected dependency converts a wiring regression from a
compile error into a silently-green one.** When a seam is injected, make the
parameter REQUIRED and pay the mechanical call-site churn (15 sites here, all in
tests) rather than covering it with a test. Also: at least one test per feature
must build the object graph the way production builds it, not by hand; per-model
tests prove the mapping and miss the wiring.

This was found by mutation check M10, the most serious find of the run.
`MatchBoard.init` and `MatchHUDModel.init` each carried
`audio: any AudioPlayer = SilentAudioPlayer()`, so deleting both `audio:`
arguments from `MatchRun` **muted the entire shipping match while all 216 tests
passed** — every cue test built its models by hand, so nothing covered the
production assembly. Fixed structurally: the defaults were removed, making it a
compile error, and `aRealRunIsWiredToTheShellsPlayer` was added driving a real
`MatchRun`.

The same shape survived one seam further out and was closed during verification.
`ShellServices.init` still defaults `audio:` (load-bearing —
`ShellModel.init` takes `services: ShellServices = ShellServices()`), and the
existing fence asserted only that `WillagramsApp.swift` *constructs* a
`SystemAudioPlayer`, not that it *hands it over*. Deleting `audio: audio` at the
root shipped a silent app with 218 green. `ServiceFenceTests.theRootInjectsItsPlayer`
now asserts the argument itself; mutation-checked RED.

Where the cues live — each fired from the model that owns the moment, never a
view, and never wrapped in a `Task`:

```
countdownTick   ShellModel's countdown re-arm
draw/swap/invalid   MatchHUDModel
win/loss + impact(.medium)   ShellModel.matchEnded
menuTap   six menu actions, AFTER their guards
tilePlace/tileRecall   MatchBoard.mirror()
```

Disclosed survivor, kept deliberately: `ShellModel:932`'s
`card.secondsRemaining != lastTick` guard. No test can drive it in either
direction.

### Item 12 — the mute control

`ShellServices` gained `audioSettings`, defaulted to `AudioSettings(defaults: .standard)`.
That default is production-correct rather than a hidden seam — the root already
uses that suite — but it means **any future test that asserts on mute MUST inject
a named `UserDefaults(suiteName:)` and `removePersistentDomain` it**, or it reads
and writes the test host's real preferences.

`ShellModel.setMuted(_:)` is the sole funnel: settings write, then player write,
then the `.menuTap` cue. `toggleMute()` delegates to it. The only two `setMuted`
call sites in `Willagrams/**` are that adjacent pair, so no path sets one without
the other. `isMuted` is seeded from `services.audioSettings.isMuted` *before* the
`guard let signIn` early return.

`MenuView` is SwiftUI and therefore excluded from ShellTests, so the only
coverage of the toggle actually being on the menu is the scoped source scan
`ServiceFenceTests.theMenuCarriesTheMuteToggle`. Keep it in sync if the labels or
the method name change.

Mute is sound only. Suppressing haptics while muted is the concrete player's own
behavior, documented in the protected `AudioPlayer` protocol; the one
`services.audio.impact(.medium)` in `ShellModel` is item 11's win haptic and is
untouched.

---

## Lane acceptance check

An independent `dt-review` read the full merged diff against the four
`Lane done when:` criteria. Verdicts:

1. **Host/join, win advances both `profiles` rows** — mechanism **MET (live)**,
   literal two-simulator tap-through **UNRUN**. `LiveMatchTests` plays a whole
   match over two real `SupabaseBackend`s; `MatchOutcomeRecorderLiveTests`
   asserts `record_outcome` advances both rows as deltas against fresh reads,
   not `0==0`. The menu-level flow is model-proven against `FakeBackend`.
2. **Friend by code, in-app invite, play to a result, read a profile under RLS**
   — every sub-mechanism **MET (live)**, literal tap-through **UNRUN**.
   `FriendsLiveTests` proves cross-user profile reads really pass RLS;
   `MatchInviteChannelLiveTests` carries a genuine positive/negative pair
   (an invite arrives; one addressed elsewhere does not).
3. **Sound cues, Release `SystemAudioPlayer`, mute persists** — **MET**. No
   `#if DEBUG` fences audio at the root; `aRealRunIsWiredToTheShellsPlayer`
   drives the production object graph rather than a hand-built one.
4. **Eleven packages green + iOS build** — **MET**, ten of eleven re-run by the
   reviewer independently, plus BUILD SUCCEEDED.

**Criteria 1 and 2 are not fully discharged.** No XCUITest target exists and
`simctl` has no tap primitive, so no agent in this repo can execute a
two-simulator tap-through. A human owes that check before ship. The three live
mechanisms are also each proven in isolation and never chained in one continuous
run, so the live suite is not end-to-end cover of the actual player journey.

## Known risks not covered by the criteria

1. **Silent lobby-abandon failures** — `OnlineMatch.abandonTask` discards the
   result with `try?`. A network blip while cancelling a lobby can leave a
   `matches` row stuck in `lobby` indefinitely, with nothing surfaced and no
   retry.
2. **Realtime invite topics are public** (filed via `/foundation`, needs a
   migration this lane was forbidden to make) — anyone who resolves a friend
   code to a UUID can subscribe with the shipped anon key and read live invite
   codes. Spoofing is shut by the recipient-side check; eavesdropping is not.
   The fix needs `config.isPrivate` **plus** a `realtime.messages` policy —
   `isPrivate` alone breaks the channel.
3. **Declining a friend request blocks permanently** with no undo (filed).

## Disclosed mutation survivor

`ShellModel:932`'s `card.secondsRemaining != lastTick` guard. No test can drive
it in either direction; kept deliberately rather than covered with a vacuous
test.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01BBbKTHe1pVkpgTvdunykC3
