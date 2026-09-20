# Lane Acceptance Review — `final`, round 3

**Branch:** `auto/final` @ `8eca6e5` → `lane/final`
**Date:** 2026-09-16
**Scope:** `git diff lane/final...auto/final` — 88 files, +6797/−461, twelve items

---

## Per-criterion verdicts

### Criterion 1 — cold launch reaches Home and stays up — **MET**

The iPad half I accepted from your evidence. The SE half I ran myself, at HEAD's build product.

- **iPhone SE 3rd gen** (`3EB28263…`): installed the app from the stated DerivedData path, cold `xcrun simctl launch` → pid **80125**. Still alive 15+ minutes later (`launchctl list` → `80125 0 UIKitApplication:com.willagrams.Willagrams`). Screenshot confirms **portrait Home renders** — full menu, buttons on one line, no mid-word wrapping.
- **Crash reports:** `ls ~/Library/Logs/DiagnosticReports | grep -i willagram` → **NONE**, ever. Not just "none new this round" — the app has never written one.
- **iPad Air 11-inch (M4)**: your evidence, accepted.

**One honest caveat on the literal wording.** One new crash report *was* written during my launch window: `PosterBoard-2026-09-16-204903.ips`, `bundleID: com.apple.PosterBoard` — a first-party Apple simulator wallpaper service, unrelated to Willagrams, almost certainly a casualty of load average 55+ with four simulators booted. Read literally ("no crash report is written to `~/Library/Logs/DiagnosticReports`") that fails the criterion. Read by intent (the app doesn't crash) it passes cleanly. I score it **MET on intent** and flag the literal so you can decide.

### Criterion 2 — every suite green serially at or above floor, BUILD SUCCEEDED — **MET**

Your serial run stands, and I did not find a reason to doubt any of it. Independent corroboration: a subagent re-ran ShellTests (**295**, `--no-parallel`), BoardTests (**293**), and OnlineTests (ScreenLockTests + PresenceHandoffTests) at HEAD — all green. Your `--list-tests` = 295 result does close LANE.md's standing parallel-vs-serial worry; I agree with that reading.

Two additional checks you did not mention, both clean:

- **No test was deleted to hold a number.** 3 `@Test` declarations removed, 106 added. Each of the 3 has a named rewritten successor (`"…the accepted section's primary action, and nowhere else"`, `"Exactly which frames each route accepts"`, and the ProfileRoute rewrite) — consistent with LANE.md's "rewritten to the new rule, not deleted".
- **The two new source files compile without an xcodeproj edit** because the project uses `PBXFileSystemSynchronizedRootGroup` (3 occurrences in `project.pbxproj`). Verified rather than inferred from BUILD SUCCEEDED — this was a real risk given `Willagrams.xcodeproj/**` is protected and untouched.

### Criterion 3 — no Supabase table, migration or live SQL — **MET**

Re-verified end to end myself, not accepted on report:

- `git diff --name-only lane/final...auto/final -- supabase/` → **0 files**.
- `bash scripts/scratch-verify.sh` → **exit 0**. `0001`–`0006` all `ok`; `schema_invariants` and `rls_behavior` green across **both** fixture passes; **55 assertions**; rows left behind `0|0|0|0`.

---

## Findings

### Important

**1. `Willagrams/Online/OnlineMatch.swift:528` — `observesPeerConnections: false` is an unpinned silent-revert site.**

This is the answer to your highest-value question: it is the *one* call site of the `MatchView.swift:79-80` shape in this round that nothing pins.

- Declaration: `Willagrams/Match/MatchSession.swift:475`, `observesPeerConnections: Bool = true`.
- `grep -rn "observesPeerConnections" Tests/` → **zero hits**. No source guard, no value pin.
- Deleting the argument compiles clean. `MatchSession.beginReceiving` (`MatchSession.swift:548-554`) then opens a **second** `for await` over the same `transport.peerConnectionStates` that `OnlineMatch.watchLobby()` (`OnlineMatch.swift:422-437`) already owns.

The codebase states its own failure mode at `MatchSession.swift:535-539`: *"reading either property twice and iterating both would divide its elements between the two iterators rather than fail, and the symptom is a message that never arrives."*

The regression is subtler than a full revert, which is what makes it worth pinning. Two readings, and I'll give both honestly because they differ:

- **Mine (worse):** every frame the session's own iterator eats never reaches the **pump body**, and the pump body is the sole maintainer of `departedPeers` (`OnlineMatch.swift:430,434`) and the host's `lobby` roster (`:431,435`). Both rot nondeterministically.
- **A second reviewer's (milder):** the pump's task is already suspended awaiting the stream *before* the session exists, so the older waiter is resumed first and the explicit forwarding still runs — leaving an extra dead `Task` rather than an observable break.

They agree on the two things that matter: **it is unpinned**, and `PresenceHandoffTests.facadeBuiltSessionSeesThePeerDrop` (`:52`) would very likely still pass with the argument deleted, because it delivers a *single* drop. Concurrent `.disconnected`/`.connected` events would expose divided delivery; a single one does not. Continuation resume order is not a contract to lean on either way.

Fix: one pin, matching what `ScreenLockTests.theLobbiesPassTheShellsObserver` already does for `activity:` — or a test that delivers two concurrent presence events. Not a live defect, so this does not block the merge, but it is the exact regression the round's own retro says to close rather than defer.

### Minor

**2. `Willagrams/Shell/ShellModel.swift:322` — `profileRefreshTask` is never cancelled.** It is the only stored `Task` on `ShellModel` missing from `deinit` (`:226-234` cancels the other five plus every entry in `declineSends`). A cross-item gap: item 6 added the property, item 9 extended that `deinit` without picking it up. Benign in practice — `[weak self]` prevents retention and the `self.currentProfile == opened` guard at `:363` makes a stale write impossible — so the only cost is a wasted backend round trip after teardown. Hygiene, and inconsistent with the file's own documented "nothing may outlive this model" invariant.

**3. `Willagrams/App/WillagramsApp.swift:30` — the `settings:` hand-over is pinned only by accident.** `ServiceFenceTests.onlyTheRootBuildsServices` (`:125-148`) asserts the root *contains* `SettingsStore(defaults:`, which catches deletion only because the argument happens to be an inline constructor call. The neighbouring `theRootInjectsItsPlayer` exists precisely because "constructing the player is not the same as handing it over" and asserts `audio: audio` explicitly. Bind `settings` to a local the way `audio` already is at `:24` and the pin evaporates silently, with `ShellServices.swift:69` defaulting `settings:` to `nil`. Same family as finding 1, one step weaker.

**4. Uncommitted work in the tree at HEAD.** `LANE.md` and `LANE_PROGRESS.md` are modified but not committed. The LANE.md edit raises the BoardTests floor **285 → 293** and flips item 12's `status:` from `not started` to done. Merge `auto/final` as it stands and neither lands — `lane/final` would carry a stale 285 floor and an item recorded as never started. Commit these before merging.

**5. Possible visual-only edge in BoardView.** A tile can be in `arriving` (deal animation, `BoardView.swift:136`) and under an active drag (`:38`) at the same time. The two `@State` are disjoint so there is no logic conflict, but a tile grabbed within the 0.45s of its own arrival may render mid-flight while being dragged. LANE.md's human-verify steps 6 and 7 already cover Draw/Swap animation and would surface it.

### Out of scope — pre-existing, flagged so it isn't mistaken for new

**`Willagrams/Shell/SoloMatch.swift:160` — `options: setup.options` is the same shape and is also unpinned.** Declaration `MatchSession.swift:825`, `options: MatchOptions = .standard`. I confirmed this file has **0 hunks** in `lane/final...auto/final`, so it predates the round and does not gate this merge. But the gap is real: `SoloSetupTests` only asserts `MatchSetup.options` (the struct field set earlier), never that `SoloMatch.start()` forwards it into the session's wire message. The two `Tests/` hits for the literal are test fixtures building their own sessions, not assertions about `SoloMatch`. Delete that argument and **every solo match silently plays under `.standard` rules regardless of what the setup screen chose**, with nothing red. Worth its own ticket in a later round.

---

## Adversarial sweeps that came back clean

Reporting these explicitly so the negatives are as checkable as the positives.

- **Protected paths — zero files touched**, across all eleven globs. `DesignTokens.swift` is untouched entirely, so the key-name constraint holds trivially. `MatchTransport.swift`, `Package.swift`, `Willagrams.xcodeproj/**`, `supabase/migrations/**`, `BackendContracts.swift`, `AudioPlayer.swift`, `Terminology.swift`, `WillagramsRules/**` — all clean.
- **No new file at the repo root.** `git diff --name-status --diff-filter=A` filtered to root-level paths returns nothing. I created no file anywhere in this review except this report. No `STANDARDS.md`.
- **Cross-item interference — no joint failure found.** Swept two owners of one state, teardown ordering, ordering assumptions, actor-hop reentrancy, gesture conflicts, and duplicated guards. The pair you'd most expect to break (item 10's screen-lock grace pause vs item 11's single presence owner) is explicitly tested *jointly* by `ScreenLockTests:476-530`, which drives the real `OnlineMatch.join(...).awaitStart()` path. Items 3 and 8 on `FriendsView` integrate coherently — `.invitePlay` is primary-only and excluded from the overflow menu at `:381`. One teardown-ordering hole in `HostLobbyModel.swift:317-337` was checked against `git show lane/final:` and confirmed **pre-existing**, not introduced here.
- **`Tests/StyleTests/StyleSrc/ButtonLabelFit.swift` is a git symlink** (mode `120000`) to the production file, matching the existing `BrandFonts`/`DesignTokens` pattern. StyleTests compiles the real source — no drift risk.
- **`AppActivity` has no listener leak.** Listeners are held weakly and pruned on *both* `add` and `send`.
- **The other new defaulted parameter this round is doubly pinned.** `ProfileModel.swift:75` `onSaved: … = { _ in }`, called from `ShellModel.swift:343`, is covered both behaviourally (`ProfileRouteTests.swift:86`) and by a literal source guard (`:118`) whose comment names this exact failure mode. `ShellServices.swift:73` `activity:` is the safe direction — the default constructs a *live* observer, deliberately.
- **Every other candidate of this shape predates the round.** `BoardGesture.Drag(inputLocked:offsets:)`, `BoardRender.cells(dragging:by:invalid:offsets:)`, `FriendsView.section(onOpen:)`, `ShellModel.startSoloPractice(seed:difficulty:handSize:options:)` (both production callers pass zero arguments by design), and `OnlineMatch.start(handSize:options:)` (pinned by `HostLobbyTests.swift:258-294`) are byte-identical to `lane/final`.

## Claims spot-checked against the diff — all accurate to the line

- Item 1: `OrientationPolicy.report(rejection:)` is `public nonisolated static func` at `:27`, `debugPrint` at `:28`. Accurate.
- Item 2: friend-code `Text`s carry `lineLimit(ButtonLabelFit.lineLimit)` + `fixedSize(horizontal: true, vertical: false)` with no scale factor (`ProfileView.swift:119,241`, `FriendsView.swift:307`). Accurate; the fourth is inside an `accessibilityLabel`, where it isn't needed.
- Item 9: the decline task re-checks `isAcceptedFriend(invite.hostID)` at `ShellModel.swift:807`. Accurate (status line says `:460` for `declineSends`, actual `:461` — off by one, immaterial).
- Item 12: `arrivalToken` is `public private(set)` with exactly **one** mutation repo-wide, `MatchBoard.swift:242` `&+= 1`, under the `:212` `guard !arrivals.isEmpty`. Verified by repo-wide grep. Accurate.
- The M8 fix is real: `MatchViewTests.swift:46-47` pins both arguments, against source with comment and blank lines stripped (`:26-33`) — so the comment-hiding mutation the round worried about cannot pass it.

Worth recording: the `activity:` chain is the best-defended wiring in the round. `AppActivity.init` defaults `center:` to `.default` *specifically* so the production path cannot be forgotten, and `AppActivityWiringTests` pins subscription, injected-instance **identity**, and the fully-defaulted shell. That is the standard finding 1 falls short of.

---

## Recommendation

**Merge `auto/final` into `lane/final`** — all three criteria met, no live defect, no protected path touched, no cross-item interference found. Commit the pending `LANE.md` / `LANE_PROGRESS.md` edits first (finding 4) or the floor and item-12 status are lost; pin `observesPeerConnections: false` (finding 1) as the first follow-up.
