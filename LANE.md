# Willagrams — final lane, round 3

## Objective

Willagrams survives a real person using it: it never crashes on an iPad, no button or code wraps mid-word on a phone, a saved name sticks, an invite can be sent from the lobby and declined from the banner, a screen lock does not silently kill the match, and the board's double-tap-then-sweep works on a letter.

Lane done when:
- A cold `xcrun simctl launch` on an iPad Simulator reaches Home and stays up — no crash report is written to `~/Library/Logs/DiagnosticReports` — and the same launch on an iPhone SE 3rd gen still reaches portrait Home.
- Every package suite is green run serially, no count below its floor, and `xcodebuild` reports BUILD SUCCEEDED on the merged branch.
- No new Supabase table, migration or live SQL exists: `git diff` touches nothing under `supabase/`, and `scripts/scratch-verify.sh` still runs 0001–0006 and both fixtures green.

Status: round 3 cut 2026-09-15 from `lane/final` @ `4fa9b70`, after round 2's ten items merged and its shutdown sequence ran green (full serial suite at floor, BUILD SUCCEEDED, scratch-verify 55 assertions, lane acceptance MET on all three round-2 criteria). Round 3 is the first evidence from a human actually playing the app: Nate installed the build on his iPhone 13 mini and iPad Air and found eight functional bugs plus four visual breakages. Plan: `~/.claude/plans/modular-booping-taco.md`. Nate's decisions: invites stay live-only broadcasts with no new table and no migration (a friend with the app closed misses the invite — accepted); the lock-screen bug is not a crash and wants a real message when the match dies, a waiting state when it is the other player, and tolerance for a brief backgrounding; the "PvP special match rules" report is dropped because the options were already identical to solo and he simply had not found the gear.

Lane: final — The final-adjustments pass after the polish hand test, now in its third round: the hand-test defects from Nate's two physical devices.

Owned — this lane's items live inside these paths:
  none of its own (a pass, like `polish`). No new scoped grant this round — `project.pbxproj` and `supabase/migrations/**` are untouched by every item below.

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
  protected — Sources/WillagramsRules/** (Contracts, BoardAnalysis, Pool, GameState, MatchMessage, MatchOptions, WordList, Resources/dictionary.txt), Tests/WillagramsRulesTests/**, Willagrams/Match/MatchTransport.swift, Willagrams/Style/DesignTokens.swift (key names — values may change and keys may be added), Willagrams/Style/Terminology.swift, Willagrams.entitlements, Package.swift, supabase/migrations/**, Willagrams/Online/BackendContracts.swift, Willagrams/Audio/AudioPlayer.swift, Willagrams.xcodeproj/**
  an unmerged lane's — fastlane/**, docs/store/** (launch)
  unowned — repo root files, .claude/**, docs/*.md, progress/**

Frozen contracts — build and test against these; they will not move:
  Sources/WillagramsRules/MatchMessage.swift + Tests/WillagramsRulesTests/Fixtures/wire-v4.json — no wire change this round
  Willagrams/Match/MatchTransport.swift
  Willagrams/Online/BackendContracts.swift — a new backend call goes on a side protocol, as `Willagrams/Online/FriendRequestForgetting.swift` does
  Willagrams/Style/DesignTokens.swift key names
  supabase/migrations/0005_invite_topic_authorization.sql — the invite RLS this round builds on; already permits a decline sent back to a friend's own topic

## Global rules

- **Tests.** Run each package serially on an idle machine, never while `xcodebuild` is running (a parallel run produced 22+ spurious timeouts):
  `swift test` (rules 53) · `swift test --package-path Tests/BoardTests` (271, XCTest — its swift-testing runner reports "0 tests", read the XCTest "Executed N tests" line instead) · `Tests/MatchTests` (128) · `Tests/StyleTests` (44) · `Tests/ShellTests` (264) · `Tests/SettingsTests` (36) · `Tests/BotTests` (68, ~7 min) · `Tests/OnlineTests` (147, 1 known pre-existing issue at `WholeMatchScript.swift:98`, live cases skip without a key) · `Tests/AudioTests` (19) · `Tests/AccountTests` (16) · `Tests/FriendsTests` (54).
  **These counts are floors.** A count may only go up. Never delete a passing test to hold a number; a test pinning behaviour this round changes is rewritten to the new rule, not deleted.
- **ShellTests has BOTH a load flake and four real standing failures. Do not conflate them.** Run it as `swift test --package-path Tests/ShellTests --no-parallel` — its cases are `@MainActor` and poll at 1ms, so running them concurrently starves them against their own 10s deadlines. Serial dropped a 12-issue run to 4. Those remaining **4 are genuine and predate round 3** (`SoloMatchTests.swift:108`, `CountdownOverlayTests.swift:68` and `:74`, `MatchRunTests.swift:276`) — reproduced at the round-2 base `4fa9b70`, in isolation, at load 8. They are item 5's job. Until item 5 lands, a ShellTests run showing **exactly those four and no others** is the expected baseline, not a regression; anything beyond them is yours. Never read the collected count (264) as the result — round 2 did, and recorded a failing suite as green.
- **ShellTests also excludes the SwiftUI view files** from its target and points its Style target at `StyleSrc`, so most Style, Friends and view-only edits are invisible to it. Before believing any ShellTests red, confirm the file you changed is even in its target.
- **Stale builds lie.** After changing any type in `Sources/WillagramsRules` or `Willagrams/Match`, run `swift package --package-path Tests/<pkg> clean` before trusting a red.
- **Views are not compiled by `swift test`.** After any SwiftUI or project edit, run `xcodebuild -project Willagrams.xcodeproj -scheme Willagrams -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/willagrams-dd-final build`. Never background it. The item isn't done until it says BUILD SUCCEEDED.
- **A crash leaves evidence.** Several items below change app lifecycle or concurrency isolation. After any such item, launch on BOTH an iPhone SE 3rd gen and an iPad Simulator and confirm no new `Willagrams-*.ips` appears in `~/Library/Logs/DiagnosticReports`. A green suite does not catch a main-actor isolation trap — round 2 shipped one.
- **An off-executor callback is a `nonisolated` function, not an inline closure.** Any callback UIKit or a backend SDK may invoke on its own executor — `requestGeometryUpdate(errorHandler:)`, realtime `onWire`/`onPresence`, a scene-phase or reachability handler — is a `nonisolated static func` on a plain policy or adapter type, passed by reference. A closure written inline inside a SwiftUI view or any other `@MainActor` context silently inherits that isolation and traps in `dispatch_assert_queue` the first time it is called off the main queue. This is exactly what item 1 fixed; items 9 and 10 touch the same class of callback.
- **A launch that does not crash is weak evidence.** Item 1's QA rebuilt the pre-fix commit and launched it clean on the same iPad, because the handler only fires on a timeout that does not reproduce on demand. So an isolation fix is proven by a compile-time pin — a real call from a non-isolated context in a test — and by the removed frame matching the crash frame, not by a green launch. Run the launch anyway; just never treat it as the proof.
- **`Tests/ShellTests/Package.swift` excludes the SwiftUI view files** from the `Shell` target, so `swift test` never compiles `ShellRootView.swift` and its siblings. Wiring inside them is pinned by reading the source range and matching contiguous substrings (`OrientationTests.rootViewWiring`). Anything provable by compiling is pinned by a real call in a test instead. A `#expect` inside `Task.detached` runs without the suite's task-locals — return the value and assert in the test body.
- **Nested-package symlinks.** `Tests/ShellTests/BoardSrc` and `Tests/ShellTests/StyleSrc` are directories of per-file symlinks. A new file under `Willagrams/Board/` or `Willagrams/Style/` stays invisible to ShellTests until it is symlinked there. Every other `*Src` is a directory symlink. The app target uses file-system synchronized groups, so a new source file needs no project-file entry.
- **A data-layer test needs a companion view-render pin.** Moving a decision out of a `View` into a plain struct or enum is right, and every item below that does it must also pin that the view actually draws what the data layer publishes. Item 3 shipped an action set no view was proven to render — a `switch` arm quietly returning `EmptyView` would have left every suite green. The same trap is live for items 6 and 10, whose whole defect is a model publishing state that no view reads.
- **Size decisions live in plain structs** (not `View`s), so ShellTests/StyleTests can assert on them. Landscape phone stays `verticalSizeClass == .compact`; portrait phone is `horizontalSizeClass == .compact` with a regular vertical class. **One exception to "no idiom checks":** the orientation lock in `Willagrams/App/` may read the idiom. Nowhere else.
- **`MatchSession` is at a Swift 6.3.3 toolchain limit.** One more *observed* stored property aborts MatchTests with `swift_task_dealloc`. New storage is `@ObservationIgnored`. Run MatchTests after every edit to that file.
- **Never touch the live backend.** No `supabase db push`, no `supabase link`, and no Supabase MCP `execute_sql`/`apply_migration` against any project. **No item this round may add a migration or edit one.** The live migration history is empty, so a push would re-run 0001–0005. Never print or commit `.env` or `Config/Secrets.local.xcconfig`.
- **`Config/Secrets.local.xcconfig` is gitignored and does not travel into a new worktree.** A build from a worktree without it silently ships an empty `SupabaseAnonKey` and every sign-in fails with "Couldn't sign in." Copy it from this worktree before building for a device; never print it.
- **Behavioral checks.** The Simulator can be booted, launched (`xcrun simctl launch`), rotated only by the app itself, and screenshotted (`xcrun simctl io booted screenshot`), but nothing can tap it (AXe cannot drive this Xcode). A screen reachable only by tapping is Nate's hand test: name it in the run summary with what to look at, and never claim it verified.
- **The comp.** `docs/design/willagrams-final.dc.html` is the visual truth for Home, Loading, Play/Join, Profile, Friends and How to Play. The repo is the truth for behaviour, and **this LANE.md wins over the comp** where they disagree. Map comp values onto existing `DesignTokens` keys; add a key only when none fits.
- Player-facing game vocabulary comes from `Terminology.swift` (protected). No new game term may be inlined. Menu and screen labels live beside the existing `title` constants in the Shell models.
- Context: `MAP.md`, `docs/design/README.md`, the plan file above.

---

- task: Stop the iPad launch crash. `ShellRootView.swift` (~63-76) reacts to `route.isGameplay` by calling `scene?.requestGeometryUpdate(.iOS(interfaceOrientations:))` with a trailing error handler that calls `debugPrint`. UIKit invokes that handler on `com.apple.root.default-qos` when the geometry request is rejected or times out, but the closure is `@MainActor`-isolated by context, so Swift's isolation check traps — `dispatch_assert_queue` → `EXC_BREAKPOINT`/SIGTRAP — and the app dies. Reproduced twice on an iPad Air 11-inch (M4) Simulator: launch, and ~15s later a `Willagrams-*.ips` whose faulting frame is `closure #4 in closure #3 in ShellRootView.routed.getter`. The iPhone SE does not hit it because its request succeeds. Make the handler safe to call from any executor — hop to the main actor before touching anything isolated, or mark the closure so no isolation is assumed — keeping the existing "a rejected rotation is not fatal" intent that the comment already states.
  guardrails:
    - The orientation POLICY does not change — iPad stays landscape, iPhone stays portrait outside gameplay. This item only fixes how a rejected request is reported
    - Do not silence the report by deleting the handler; a persistent rejection must still be visible
    - No `project.pbxproj` edit — the orientation keys are already correct and the file is protected this round
  done when:
    - A cold launch on an iPad Simulator reaches Home and writes no new crash report to `~/Library/Logs/DiagnosticReports`, repeated three times
    - A cold launch on an iPhone SE 3rd gen Simulator still reaches portrait Home with no new crash report
    - A test pins that the rejection path does not require main-actor isolation
    - ShellTests green at or above 263; `xcodebuild` BUILD SUCCEEDED
  caution: true
  status: done — the `debugPrint` moved out of the inline closure into `nonisolated static func OrientationPolicy.report(rejection:)`, passed by reference as `errorHandler:`, so it no longer inherits `@MainActor`. No `Task {}` hop, so mask-update ordering is unchanged. ShellTests 264, `xcodebuild` BUILD SUCCEEDED, 3 clean iPad cold launches + 1 iPhone SE portrait launch, no new crash report. Commit `493452a`. NOT verified, needs a human: that a *successful* rotation applies the landscape mask, and the gameplay re-request

- task: Buttons and friend codes stop wrapping mid-word. `Willagrams/Style/ButtonStyles.swift` (~15-26 primary, ~36-54 quiet) sets no `lineLimit`, no `minimumScaleFactor` and no `fixedSize`, and its compact font engages only on `verticalSizeClass == .compact` — landscape phone. A portrait phone therefore gets the full 20pt semibold plus 24pt horizontal padding per button, which is why Nate's screenshots show "Copy" broken across two lines as `Cop`/`y`, `Standa`/`rd` in Solo, and friend codes wrapping under the name. Give the shared styles a single-line rule with a scale floor, and engage the compact font on a portrait phone (`horizontalSizeClass == .compact`) as well. Apply the same guard plus `fixedSize` to the friend-code text in `FriendsView.swift` (the "Your code" card ~182-205 and the per-row code ~329-332) and `ProfileView.swift` (~234-261). Fix it in the shared style, not at each call site — every caller already routes through it.
  guardrails:
    - One change in the shared styles; do not paste `lineLimit` at individual call sites that the styles already cover
    - A friend code must never be scaled to the point of illegibility or truncated with an ellipsis — it has to stay readable and copyable in full
    - Landscape phone and iPad layouts do not regress
  done when:
    - No label rendered through the shared button styles wraps to a second line at 375pt width; a test pins the single-line rule and the portrait-phone compact font
    - The friend code renders in full on one line on both the Profile card and a friend row
    - StyleTests green at or above 34, FriendsTests at or above 49, AccountTests at or above 16; `xcodebuild` BUILD SUCCEEDED
  caution: true
  status: done — a new plain enum `Willagrams/Style/ButtonLabelFit.swift` holds the shared rule (lineLimit 1, minimumScaleFactor 0.8, `isCompact = vertical == .compact || horizontal == .compact`, pointSize, horizontalPadding), consumed by all three button styles and by `StatRow`. The four friend-code `Text`s take lineLimit + `fixedSize(horizontal:)` with deliberately NO scale factor, so a code can never shrink or ellipsise. StyleTests 34 → 42, Friends 49, Account 16, `xcodebuild` BUILD SUCCEEDED. Commits `9085479`, `ed5232f`. Mutation-checked both ways: reverting `isCompact` to landscape-only turned StyleTests red with a real CoreText overflow (333.5pt into a 295pt row), and an unguarded `Text(peer.friendCode)` planted in a third view was caught by the rewritten repo-wide scan. NOT verified, needs a human: the Profile card, the Friends cards and the Solo StatRow are reachable only by tapping

- task: The friend row fits a phone. Even at the compact font, three labelled buttons will not fit the ~310pt card `FriendsView.swift` gives a row (~307-342) — Nate's screenshot shows three enormous vertical bars where "Invite to play", "Unfriend" and "Block" should be, in both the accepted section (~93-108) and the "Wants to be friends" section (~65-82). Keep the primary action visible on the row and move the destructive ones into an overflow menu. Reuse the existing unfriend confirmation dialog (~143-152) rather than adding a second one.
  guardrails:
    - Every action available today stays available — Invite to play, Unfriend, Block, Accept, Decline. None may be dropped, only relocated
    - Unfriend still asks before acting, through the existing dialog
    - Unfriending still never removes a block (the round-1 rule)
  done when:
    - A friend row renders at one card height at 375pt width with no button wrapping
    - Each of Accept, Decline, Block, Invite to play and Unfriend is still reachable, and a test pins that the row's action set is unchanged
    - FriendsTests green at or above 49; `xcodebuild` BUILD SUCCEEDED
  ui: true
  status: done — the row now shows one primary labelled button (Accept / Invite to play) plus a labelled `ellipsis.circle` overflow Menu holding Decline, Block and Unfriend, with Block and Unfriend carrying `role: .destructive` and the menu an `.accessibilityLabel`. The action set moved out of the view into plain `FriendRowAction`/`FriendRowSection` enums in `FriendsModel.swift`, so a test pins it without matching view nesting. Measured 375pt budget: 237pt available, new cluster ~180pt, and a companion test pins that the old three-button cluster at ~278pt would NOT have fit. FriendsTests 49 → 54, StyleTests 42 → 44, `xcodebuild` BUILD SUCCEEDED. Commit `46a3fa2`. `InviteRowTests.swift` was rewritten, not deleted — its byte-offset ordering assertions stopped existing once both sections route through one helper; QA audited the rewrite for cover-up and kept every check that still had teeth. NOT verified, needs a human: the Friends screen opens only by tapping, so there is no screenshot of the fixed row

- task: Solo Practice stops saying HOST. `Willagrams/Settings/Views/MatchOptionsView.swift:39` hard-codes `Text(verbatim: "HOST")` in the non-embedded header, and Solo's setup screen (`SoloSetupView.swift` ~79) renders exactly that header — so a single-player screen is labelled HOST. Make the eyebrow the caller's choice with no "HOST" default, or move it into the embedded-only branch, so Solo shows no eyebrow and the host lobby still shows its own.
  guardrails:
    - The host lobby's embedded options card keeps whatever eyebrow it shows today
    - No change to which options are offered in either place — solo and PvP already render the same form and that is correct
  done when:
    - Solo setup renders no "HOST" text; a test pins its absence there and its presence in the host lobby
    - SettingsTests green at or above 36, ShellTests at or above 264; `xcodebuild` BUILD SUCCEEDED
  status: done — the hard-coded `Text(verbatim: "HOST").monoLabel()` is gone from `MatchOptionsView`'s non-embedded header, which only ever reached solo setup. **The trap this item's dispatch warned about was FALSE, and the engineer re-derived it before building:** the host lobby calls `MatchOptionsView(form:embedded: true)` at `TwoPlayerView.swift:167`, and the `embedded` branch returns `rows` only — it never rendered that header. The lobby's eyebrow is its own, `Text(Self.screenLabel).monoLabel()` at `TwoPlayerView.swift:106` with `screenLabel = "TWO PLAYER"` at `:399`. So no parameter was needed, and deleting the literal cannot strip the lobby. SettingsTests 36 → 37, `xcodebuild` BUILD SUCCEEDED. Commit `09d2f26`. The guard is a repo-wide comment-stripped scan with a `scanned >= 50` floor plus a positive pin on the lobby's own eyebrow, so satisfying it by deleting the lobby's label turns the same test red. Both mandated mutation checks went red then restored byte-clean. Known ceiling: the scan bans the substring `"HOST"` in any app source, so a future legitimate literal (a hostname key) needs an exemption. NOT verified, needs a human: both screens open only by tapping. Out of scope but noted — solo setup still nests the whole non-embedded `screen` (canvas gradient, page padding, card, its own "Match options" title) inside its own page

- task: The Shell suite tells the truth. `Tests/ShellTests` has **four standing failures that predate round 3** — verified identical at the round-2 merge base `4fa9b70`, in isolation, at a 5-minute load average of 8, so they are neither regressions nor the documented load flake. They were mistaken for the load flake twice, and round 2's shutdown sequence recorded the suite as green by reading its collected count (264) instead of its result. Every item below gates on this suite, so it has to be honest before they run. (a) `SoloMatchTests.swift:108` `#expect(opener.poolRemaining == nil)` fails with `102`: round 1's "Guest bag count" item deliberately made BOTH ends see the tiles left in the bag, and this test still pins the pre-round-1 rule that a non-pool-host sees nothing. Rewrite it to the shipped rule. (b) and (c) `CountdownOverlayTests.swift:68` and `:74` both time out. That file drives a `StepClock` specifically so no wall-clock time is involved — its own comment says "three seconds cost nothing and cannot flake" — and it rests on the stated assumption that "the session's countdown is the only thing that sleeps in these tests, so a suspended sleeper is always the countdown waiting for its next tick." Find out whether a second sleeper now shares `sleepFor`, which would make `clock.advance()` resume the wrong one and strand the countdown; if so the assumption, not the countdown, is what broke. (d) `MatchRunTests.swift:276`, a dropped shell and its run are never released — investigate whether this is a genuine retain cycle before touching the test, because a real leak here is a real bug.
  guardrails:
    - A test pinning behaviour that genuinely changed is REWRITTEN to the shipped rule, never deleted and never weakened to pass. If any of these four turns out to be pinning a real defect, fix the defect instead and say so
    - (d) is a leak check. Do not make it pass by extending its deadline or dropping the assertion until you have established whether the shell is actually released
    - Do not touch `MatchSession`'s grace or sleep behaviour here beyond diagnosis — item 9 owns that change, and this item must not pre-empt it
  done when:
    - `swift test --package-path Tests/ShellTests --no-parallel` reports 0 issues, and the count is at or above 264
    - Each of the four is resolved as either "test rewritten to the shipped rule, with the rule named" or "product defect found and fixed", stated per failure — never silently dropped
    - The same command is green twice consecutively, and a `--filter` run of each affected suite alone is green
    - `xcodebuild` BUILD SUCCEEDED
  caution: true
  status: not started

- task: A saved name reaches the whole app. `ProfileModel.save()` (`Willagrams/Account/ProfileModel.swift` ~128-148) already writes the new display name and succeeds — the name is in the database. But `ShellModel.currentProfile` (`Willagrams/Shell/ShellModel.swift:99`) is assigned in exactly one place, the sign-in task at ~207, and the save never writes back, so `showProfile()` (~324-336) rebuilds the screen from the stale row on every visit and the old name reappears. Hand the saved row back to the shell so `currentProfile` updates. Fix the second defect in the same file while there: `canSave` (~120-122) omits a backend check while `save()` (~129) returns silently when the backend is nil, so with no backend the Save button is enabled and does nothing without a word to the player — fold the check into `canSave` and say why.
  guardrails:
    - The name length rule (1...24, trimmed) and the existing validation messages do not change
    - Do not add a second source of truth for the profile — `ShellModel.currentProfile` stays the one the app reads
  done when:
    - After a successful save, `ShellModel.currentProfile` carries the new name, and reopening Profile shows it; a test asserts the shell's copy changed, not only the screen's
    - With a nil backend, Save is disabled and the screen says why, instead of being enabled and silently doing nothing
    - `ProfileRouteTests.swift` (~83) is rewritten to the new rule rather than deleted; AccountTests green at or above 16, ShellTests at or above 263
  caution: true
  status: not started

- task: Joining a friend's game says it worked. `JoinModel` already computes `waitingTitle` (~112), `waitingLine` (~137) and `hostName` (~82); all three are tested and **no view reads any of them** — `TwoPlayerView` never looks at `join.phase`, so after a guest enters a code the screen gives no sign the join succeeded. Render the state the model already publishes: the `.joining` phase shows progress, the `.waiting` phase shows that the join worked and names the host being waited on. This is wiring over existing, already-tested code — do not restate the copy in the view.
  guardrails:
    - The copy stays `JoinModel`'s; the view renders it and decides nothing
    - The join flow itself does not change — only what the guest is shown about it
  done when:
    - After a successful join the guest sees a waiting state naming the host, and during the attempt sees a progress state
    - A test pins that the view reads `join.phase` and renders each phase's published line
    - ShellTests green at or above 263; `xcodebuild` BUILD SUCCEEDED
  ui: true
  status: not started

- task: Invite a friend from the open seat. Invites already work end to end as live Realtime broadcasts on a private `invites:<uuid>` topic — `MatchInvite.swift`, `SupabaseMatchInviteChannel.swift`, `ShellModel.inviteArrived(_:)` (~605), the banner in `ShellRootView.swift` (~81-100) — and `0005_invite_topic_authorization.sql` already restricts sending to accepted friends. The only gap is reach: `ShellModel.invitePlay(_:)` guards `guard case .friends = route` (~722), so an invite can be sent only from the Friends list and never from the lobby where you are actually sitting waiting for someone. Extract the send half of `invitePlay` (~721-760) into a helper that takes an already-open lobby, so the Friends path and a new lobby path share one implementation, and add a friend picker to the open-seat row in `TwoPlayerView.swift` (~343-365) listing accepted friends only.
  guardrails:
    - No new table, no migration, no live SQL — an invite stays a broadcast and only a broadcast
    - The existing Friends-list entry point keeps working unchanged, including its `route == .friends` guard
    - Only accepted friends may be listed or invited; a pending or blocked relationship must not appear in the picker
  done when:
    - The host can send an invite from the open seat without leaving the lobby, and the same invite arrives as the banner the Friends-list path produces
    - A pending-request or blocked person never appears in the picker; a test pins the accepted-only rule
    - `git diff` touches nothing under `supabase/`; ShellTests green at or above 263, OnlineTests at or above 147
  ui: true
  status: not started

- task: Decline a match invite. The banner in `ShellRootView.swift` (~95) offers Join and nothing else, so an unwanted invite can only be ignored. Add a Decline beside Join that clears the banner, and tell the host: send a decline back on the host's own `invites:<hostID>` topic, which the existing policy `invites_send_to_accepted_friend` in `0005` already permits — the recipient is an accepted friend of the host, so no migration is needed. Show the host that the invite was declined at the open seat. `ShellModel.showsInvites(_:)` (~518) currently allows only `.menu, .friends, .profile, .join`, so the host sitting on `.hostLobby` cannot receive the decline — widen it to accept a decline frame there.
  guardrails:
    - No new table, no migration, no live SQL
    - Declining must not send a match invite back, block, or unfriend — it is one message and nothing more
    - A decline must not be able to reach a stranger: the same accepted-friend restriction that governs an invite governs a decline
    - `InviteTests.swift` (~389 `onlyFourRoutesShowInvites`) pins the old route rule — rewrite it to the new rule, never delete it
  done when:
    - Declining clears the banner on the guest's device and the host sees that the invite was declined at the open seat
    - The host receives a decline while on `.hostLobby`, and a rewritten `onlyFourRoutesShowInvites` pins exactly which frames each route accepts
    - `git diff` touches nothing under `supabase/`; ShellTests green at or above 263, OnlineTests at or above 147
  caution: true
  status: not started

- task: A screen lock no longer kills the match. There is no scene-phase observer anywhere in the app — a sweep finds lifecycle handling only in `Willagrams/Audio/SystemAudioPlayer.swift` (~85). Locking the phone suspends the process and drops the websocket, and on resume two stacked graces fire at once: `MatchSession.reconnectGraceSeconds` (30s) reaches `awayPeersAreGone()` (`MatchSession.swift` ~565-579), which is one-way and cancels the pump; and `RealtimeMatchTransport.defaultPeerGrace` (35s, ~105) reaches `close()`, finishing the `inbound`/`states` AsyncStreams (~212-213), and a finished AsyncStream cannot restart — the `for await` loops in `beginReceiving` (~483, ~490) exit permanently. The UI stays responsive because SwiftUI is unaffected, which is exactly what Nate reported: everything responds except Draw and Swap, which route through the dead pump. Add the app's first scene-phase observer and route it into the online stack so a brief backgrounding is survivable: the graces must not spend their budget while suspended, and on resume the transport re-subscribes before they resume counting. Note `MatchSession.swift` (~544) already builds a wall-clock `Date` deadline while the wait itself is `sleepFor`-driven, so the two disagree by exactly the suspend duration — pick one clock.
  guardrails:
    - `MatchSession` is at a toolchain limit — any new stored property there is `@ObservationIgnored`, and MatchTests runs after every edit to that file
    - A peer who is genuinely gone must still be detected; this item makes the grace honest about suspended time, it does not make it infinite
    - Do not change the wire format or `MatchTransport`; both are frozen contracts
    - `SupabaseMatchChannel.swift` (~81-93) has a presence `retrack` workaround for supabase-swift 2.55.1 losing presence after a socket drop — a screen lock takes exactly that path. Do not remove it
  done when:
    - A match survives a 60-second background-and-resume: Draw and Swap still work afterwards, pinned by a test that drives the scene-phase transition against a fake clock
    - Time spent backgrounded does not count against either grace, and the session's deadline and its sleep agree on one clock
    - A peer that never returns is still reported gone after the grace, so the fix does not hang a dead match forever
    - MatchTests green at or above 128, OnlineTests at or above 147, ShellTests at or above 263; no new crash report on an iPhone or iPad Simulator launch
  caution: true
  status: not started

- task: A dead match says so. When the graces really do expire, `awayPeersAreGone()` (`MatchSession.swift` ~565-579) cancels the pump and nothing at all reaches the player — Draw and Swap simply stop responding with no message, which is what Nate read as a crash. Surface the end state instead of dead buttons, and while a peer is inside the reconnect window show that the game is waiting on them rather than leaving a frozen board. Nate's words: if the game dies it should say so, and if it is waiting on the other player it should show a waiting state.
  guardrails:
    - Do not extend or shorten the grace here — this item reports the outcome, item above owns the timing
    - The waiting state must be distinguishable from the ended state; a player must never be told the match ended while it can still recover
  done when:
    - When the reconnect grace expires the player sees that the match ended, instead of unresponsive Draw and Swap buttons
    - While a peer is inside the reconnect window the board shows a waiting indicator naming that it is waiting on the other player
    - A test pins both states and the transition between them; MatchTests green at or above 128, ShellTests at or above 263
  ui: true
  status: not started

- task: Double tap then slide works when the slide starts on a letter. The grab decision in `BoardGesture.swift` (~130-143) is already correct — in selection mode a letter the selection does not hold becomes `.paint`, pinned by `BoardSelectionTests.swift` (~482). The fault is upstream: `selection.isActive` is still false when the sweep begins, because the double tap never reaches `enterSelection()` when it lands on a letter. `DragGesture(minimumDistance: 0)` (`BoardView.swift` ~203) claims every touch-down; on a bare cell the grab is `.pan` and nothing is written, so the tap pair completes, but on a letter `model.began` builds a `TileDrag` and fires a haptic (~406-417) and the tap's release commits a zero-translation drop inside `withAnimation` (~429-452), writing the owner's `@Observable` board and model state between the first and second tap. `Drag.grab` is a `let` decided once (~40-41), so a late `enterSelection()` cannot rescue a drag already decided `.tile`. Make a tap on a tile write nothing: keep `minimumDistance: 0`, which is load-bearing for pan and paint and the documented reason `.highPriorityGesture` was rejected (~247-251), but defer building the `TileDrag` for a `.tile` grab until the translation clears a small threshold, leaving `.pan` and `.paint` beginning at touch-down as they do now.
  guardrails:
    - `minimumDistance: 0` stays, and the double tap stays `.simultaneousGesture` — `BoardSourceTests.swift` (~805) pins both by source scan and records that a competing tap loses every sequence to a zero-distance drag
    - Dragging a tile must still feel immediate; the threshold is the smallest that stops a tap from committing, not a perceptible delay
    - The grab decision itself does not move — it stays decided once, at touch-down, in `BoardGesture`
  done when:
    - A `.tile` grab whose drag never moved commits nothing, writes no board or model state and fires no pickup or snap haptic; a test pins this
    - Sweeping from a letter after a double tap selects multiple tiles, verified by Nate on a device
    - BoardTests green at or above 271 (read the XCTest "Executed N tests" line) and every existing selection and drag pin stays green; `xcodebuild` BUILD SUCCEEDED
  caution: true
  status: not started

- task: Letters draw when they should. Two independent faults make tiles appear late or lag behind the grid. First, `BoardView.swift` (~704-707) animates on `value: Set(cells.compactMap { $0.tile?.id })` with a 0.45s ease-out; its comment says the set changes only on a draw, a swap or the deal, but `cells` is viewport-culled (`BoardRender.swift` ~97), so the set changes every time any tile crosses the viewport edge — every pan, pinch, recenter and the opening framing — restarting a 0.45s animation over every tile's offset, which is why letters trail the board. Key it on the tiles on the board rather than the culled view, matching the intent already written. Second, `arrivedToken` is `@State` initialised to 0 (~125) while the owner's `arrivalToken` is already at least 1, and countdown and match are separate `switch` branches in `ShellRootView`, so the match screen's fresh `BoardView` re-arms the entire opening hand as `.fromBag` — starting at the bag corner at opacity 0 — for ~0.47s; seed it from the owner's current token on appear. Delete `arrivalProgress`, `arrivalCorner` and `arrivalScale` (~117, ~182, ~572, ~581, ~587) while there: all three are written and passed but never read, and the flight is actually driven by the transition at ~688.
  guardrails:
    - A genuine new tile from a Draw or a Swap must still fly in from the bag — this item stops tiles already on the board from re-flying, and must not disable the arrival animation
    - `BoardRenderTests.swift` (~358, ~378) pins arrival classification, including the pan-into-view case; both stay green
    - Deleting the dead state must not change any rendered geometry — confirm the three properties are genuinely unread before removing them
  done when:
    - Panning or pinching a board no longer restarts the deal animation: a test pins that the animation's trigger value is independent of which tiles are currently visible
    - Entering a match does not re-fly the opening hand from the bag; a test pins that an already-delivered batch is not re-armed by a freshly built view
    - Letters stay with their cells during a pan and are on screen when the board appears, verified by Nate on a device
    - BoardTests green at or above 271; `xcodebuild` BUILD SUCCEEDED
  caution: true
  status: not started

## Not yet specified

- Whether the reconnect grace should differ between a lock-screen suspend and a force-quit — a force-quit is unrecoverable and could be reported faster than 30s, but nothing distinguishes them today. Revisit after the scene-phase item.

## Out of scope

- PvP special match rules. Dropped 2026-09-15: solo and Play a Friend already render the same `MatchOptionsView` off the same form and the same `SettingsStore`, and the only solo-exclusive control is bot difficulty. Nate had not found the gear; the delta is zero.
- A persistent invites table. Nate chose live-only broadcasts: a friend with the app closed misses the invite, and that is accepted for now. Revisiting it means a migration, which this round forbids.
- Real Multiplayer (three or more players, matchmaking). Home keeps its disabled placeholder.
- iPad portrait and iPad multitasking. iPad stays landscape — the crash item fixes how a rejected rotation is reported, not the policy.
- Dynamic Type. `BrandFonts.swift` (~80, ~86) uses `.custom(_, fixedSize:)` so no text in the app scales at all. App-wide and pre-existing; it deserves its own round.
- The white system launch-screen flash before the dark loading screen takes over. Round 2 left it; it needs a launch-storyboard change and `project.pbxproj` is protected this round.
- `HostLobbyLayout.swift`, a confirmed orphan kept alive only by its own test. Delete both in a cleanup round.
- Sign in with Apple and the `launch` lane. Both wait on the paid Apple Developer membership.
