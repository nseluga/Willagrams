# Willagrams — Lane: shell, round 3

## Objective

Every screen the release ships that does not need the paid Apple membership is
reachable from the menu and works against the live backend: play a friend over
the network, a profile with stats, a friends list with in-app invites, and
sound.

Lane done when:
- On two simulators running the merged branch (Debug), one player hosts from
  the menu and shows an invite code, the other joins with it, both reach the
  match screen, and a win on one shows results on both with both `profiles`
  rows advanced by `record_outcome`.
- Two players on separate simulators friend each other by code; one taps the
  other in the friends list; the second sees the invite in-app, accepts, and
  they play a match to a result; either can open the other's profile and see
  their stats, read from the real database under RLS.
- In a solo match a tile placement, a Draw, and the win call each reach the
  app's one `AudioPlayer` with the matching `SoundEffect`; the app root builds
  `SystemAudioPlayer` in a Release build; muting persists across relaunch.
- All eleven test packages are green and
  `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build`
  succeeds.

Lane: shell — App shell: launch, opening animation, the home page and its actions (start a match, how to play), the countdown/match/results routes and the navigation between them, in-match HUD, results and rematch. Feature lanes own their own screens; shell navigates into them. **Round 3, under the MAP grant of 2026-09-03, also owns the `account` and `friends` areas and wires every merged seam the menu still does not call.**

Owned — this lane's items live inside these paths:
  Willagrams/Shell/**
  Willagrams/App/**
  Tests/ShellTests/**
  Willagrams/Account/**      (granted 2026-09-03 — this round creates it)
  Tests/AccountTests/**      (granted 2026-09-03 — this round creates it)
  Willagrams/Friends/**      (granted 2026-09-03 — this round creates it)
  Tests/FriendsTests/**      (granted 2026-09-03 — this round creates it)

Open — merged lanes. Wiring items may edit these; rebase onto `integration` first:
  Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md (style)
  Willagrams/Board/**, Tests/BoardTests/** (board)
  Willagrams/Match/**, Tests/MatchTests/** (match)
  Willagrams/Settings/**, Tests/SettingsTests/** (settings)
  Willagrams/Bot/**, Tests/BotTests/** (bot)
  Willagrams/Online/**, Tests/OnlineTests/**, supabase/** except supabase/migrations/** (online)
  Willagrams/Audio/**, Tests/AudioTests/** (audio)

Stop and report if an item requires changing a path outside both lists:
  protected — Sources/WillagramsRules/Contracts.swift, BoardAnalysis.swift, Pool.swift, GameState.swift, MatchMessage.swift, MatchOptions.swift, WordList.swift, Resources/dictionary.txt; Tests/WillagramsRulesTests/**; Willagrams/Match/MatchTransport.swift; Willagrams/Style/DesignTokens.swift; Willagrams/Style/Terminology.swift; Willagrams.entitlements; Package.swift; supabase/migrations/**; Willagrams/Online/BackendContracts.swift; Willagrams/Audio/AudioPlayer.swift
  an unmerged lane's — fastlane/**, docs/store/** (launch)
  unowned — `.` (repo root: MAP.md, Package.swift, README, .gitignore, Willagrams.entitlements) · `.claude/**` · docs/*.md · progress/** · Sources/WillagramsRules/** and Tests/WillagramsRulesTests/** · Willagrams.xcodeproj/**

Frozen contracts — build and test against these; they will not move:
  style — Willagrams/Style/DesignTokens.swift (key names; values may change under you), Willagrams/Style/Terminology.swift. Fixture: Tests/StyleTests (30). Already consumed by every shell screen; no new wiring item.
  board — Willagrams/Board/BoardView.swift, binding-based init. Fixture: Tests/BoardTests (253). Consumed by MatchView; no new wiring item.
  match — Willagrams/Match/MatchTransport.swift and MatchSession's public surface. Fixture: Tests/MatchTests (125) and Tests/WillagramsRulesTests/Fixtures/wire-v3.json. Consumed by MatchRun; no new wiring item.
  bot — Willagrams/Bot/BotMatch.swift, BotDifficultyMenu.swift. Fixture: Tests/BotTests (68). Consumed by SoloMatch; no new wiring item.
  settings — Willagrams/Settings/Views/MatchOptionsView.swift (`init(form: Binding<MatchOptionsForm>)`), Willagrams/Settings/Model/SettingsStore.swift (`load()`, `save(_:)`). Fixture: Tests/SettingsTests (36). Wiring item: 6.
  online — Willagrams/Online/OnlineMatch.swift (`host(options:backend:...)`, `join(code:backend:...)`, `inviteCode`, `lobby`, `start()`, `awaitStart()`), Willagrams/Online/BackendContracts.swift (`BackendClient`), Willagrams/Online/SupabaseBackend.swift (`init()` reads the anon key itself; `signInAnonymously()` is `#if DEBUG`). Fixture: Tests/OnlineTests (126; 22 live cases gated on `WILLAGRAMS_LIVE_TESTS=1` and `SUPABASE_ANON_KEY`). `Tests/OnlineTests/Cases/WholeMatchScript.swift` is the reference call sequence for a whole online match. Wiring items: 3, 4, 10.
  audio — Willagrams/Audio/AudioPlayer.swift (`AudioPlayer`, `SoundEffect`, `HapticStrength`, `SilentAudioPlayer`), SystemAudioPlayer.swift (`init(bundle:muted:)`), AudioSettings.swift (`init(defaults:)`, `isMuted`, `setMuted(_:)`). Fixture: Tests/AudioTests (19). Wiring items: 11, 12.

Test against the fixture, not the producing lane. Do not wait for it to exist.

Items scope to this lane's owned paths plus the open merged-lane paths a wiring
item reaches. An item needing a `protected:` or unowned change is not a lane
item — it is an amendment request.

## Status

Rounds 1–2 built a solo match that plays start to finish in Release against
`BotMatch`. Since then `online` and `audio` merged with zero callers: no screen
constructs a `SupabaseBackend`, an `OnlineMatch` or any `AudioPlayer`, and the
menu still offers exactly two actions. `SoloSetupView` hand-rolls the option
rows `MatchOptionsView` already provides, and `SettingsStore` has no caller in
the app. `Willagrams/Account/` and `Willagrams/Friends/` do not exist.

Identity this round is the anonymous session `online` proved live. It is
`#if DEBUG` on purpose, so every online, profile and friends criterion runs in
a Debug build (what Xcode installs on a simulator or a free-team device). The
Release criterion covers solo play and audio only. Sign in with Apple sits
below the stop marker on the Apple Developer membership.

## Global rules

- **No SwiftUI view in this repo can be tested headlessly.** Every test package
  builds for macOS and excludes every View. Every decision, transition and
  derived string lives in an observable model or a pure function; views stay
  thin. A view holding a branch that changes behavior is a defect. **Every new
  View file must be added to its package's `exclude:` list** or the suite stops
  building — `SourceGuardrailTests` in ShellTests fails first and says so; the
  two new packages carry the same guardrail from their first commit.
- **New test packages follow the symlink pattern and its hazard.**
  `Tests/AccountTests` and `Tests/FriendsTests` symlink their own source
  directory plus `Willagrams/Online` (for `BackendContracts` and `FakeBackend`)
  and `Willagrams/Match` (Online compiles against `MatchTransport`), exactly as
  `Tests/OnlineTests/Package.swift` does. Board's SwiftUI files never compile
  on macOS: never symlink `Willagrams/Board` as a directory. A path reached
  through a symlink belongs to the lane that owns its target.
- **Friends is tested against the real database, not `FakeBackend`.** RLS
  refuses a read by returning zero rows and a write by affecting zero rows,
  never an error; the fake enforces no policy. Friends items carry live-gated
  cases on the OnlineTests pattern (`WILLAGRAMS_LIVE_TESTS=1` and
  `SUPABASE_ANON_KEY` from `.env`), each on freshly signed-in anonymous users
  it creates itself. Green with the gate skipped is not green.
- **Secrets never enter git.** `.env` and `Config/Secrets.local.xcconfig` are
  gitignored and already present in this worktree. No item writes a key into
  source, a test, a fixture or a log.
- **Never `import GameKit`.** `Tests/MatchTests/Cases/SourceGuardrailTests.swift`
  asserts no file ever does.
- **`Terminology.swift` is frozen and is the IP fence.** Use its names for game
  concepts. Screen chrome it does not define ("Play a Friend", "Friends",
  "Profile", "Invite code", "Join", "Waiting for host", "Reconnecting") is
  declared local to the view that uses it, per the `BoardView.recenterLabel`
  precedent. Bananagrams vocabulary (Bunch, Split, Peel, Dump, Bananas, Rotten)
  never appears in player-facing copy.
- **`MatchSession` is at a Swift 6.3.3 toolchain limit.** One more observed
  stored property aborts MatchTests in the reconnect path. No item here adds
  state to it; consume `peerPresences`, `presence(of:)`, `isMatchOver` as they
  are.
- **`AudioPlayer.play` and `.impact` are non-async, non-throwing, called from
  the main actor.** Never wrap a cue in a `Task` or a `do/catch`.
- **Each nested test package needs its own literal `--package-path` command.**
  A shell variable does not word-split. The eleven after this round: `.` (53),
  `Tests/BoardTests` (253, XCTest — "Executed N"), `Tests/MatchTests` (125),
  `Tests/StyleTests` (30), `Tests/ShellTests` (125), `Tests/SettingsTests`
  (36), `Tests/BotTests` (68, ~5 min), `Tests/OnlineTests` (126),
  `Tests/AudioTests` (19), `Tests/AccountTests` (new), `Tests/FriendsTests`
  (new). Two cases are wall-clock flaky under a full parallel run and pass
  alone: BotTests' pacing case and ShellTests' countdown overlay.
- **`swift test` never compiles SwiftUI.** Only
  `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build`
  does. Every item that touches a View runs it.
- **Two-device behavioral checks run on two simulators** booted with
  `xcrun simctl`, each holding its own anonymous session. Never two instances
  on one simulator: they would share the keychain and the session.
- Fuller context: `MAP.md` (the grants, the symlink hazard, the "Decided"
  sections on audio and the Release fence), `FOUNDATION.md` (frozen contracts
  and the open broadcast-ordering risk), `docs/design/README.md` (the comp,
  screen by screen, and what it deliberately does not build), `docs/schema.md`.

## Not yet specified

- What the guest sees between accepting an invite and the countdown when the
  host is slow to press Start — a plain waiting screen this round; whether it
  needs a cancel that also tells the host is unknown until item 10 shows how
  cancellation propagates. Revisit after item 10.

## Out of scope

- Sign in with Apple — needs the paid Apple Developer membership; below the
  stop marker, and `signInWithApple` on `SupabaseBackend` still throws.
- Lifting the `#if DEBUG` fence on anonymous sign-in — a launch-day product
  decision about guest accounts; Supabase identity linking keeps it reversible
  then. Release stays solo + audio this round.
- Online rematch — a new match row and a re-invite; solo keeps its rematch,
  online results offer Main Menu only.
- Sound asset files — none exist in the bundle, so every cue is a silent no-op
  until the audio lane's assets land. The call sites are this round's; the
  files are not code.
- Per-sender sequence number on `WireEnvelope` — `FOUNDATION.md`'s open risk,
  `online`'s to schedule; out-of-order moves are a real defect but not shell's.
- Lobbies of more than two — `OnlineMatch.start()` requires exactly two; the
  wire allows six, the façade does not, and widening it is an online item.
- Launch screen (design comp 01) — needs an `Willagrams.xcodeproj` edit,
  Reviewer-only.
- A first-launch name prompt — "Player XXXX" is the anonymous default and is
  editable on the profile screen; one fewer screen before Solo Practice.
- A standalone settings screen — no screen exists to host a mute row, so the
  control is a menu toggle; the results stat table and pool-size pickers stay
  cut per `docs/design/README.md`.
- Push notifications for invites — APNs needs the paid membership; invites
  reach a friend only while their app is open, by design.
- The friends "unfriend" action — `BackendClient` has no call for it; `block`
  is the only removal and adding one is a `/foundation` amendment.

---

- task: |
    Build the app's services once, at the root, and inject them.

    `Willagrams/App/WillagramsApp.swift` constructs one `SupabaseBackend()`
    (its `init` reads the anon key from `Info.plist` via the gitignored
    xcconfig — pass nothing), one `SystemAudioPlayer(muted:)` seeded from
    `AudioSettings(defaults: .standard).isMuted`, and one
    `SettingsStore(defaults: .standard)`, and hands them to `ShellModel` as a
    single `ShellServices` value declared in `Willagrams/Shell/`. `ShellModel`'s
    existing `init` gains the parameter with a default that ShellTests override
    with `FakeBackend`, a recording `AudioPlayer`, and an in-memory
    `UserDefaults(suiteName:)`.

    At launch, in Debug, `ShellModel` signs in with
    `SupabaseBackend.signInAnonymously()` and publishes the resulting `Profile`
    as `currentProfile: Profile?`. Sign-in is a `Task` the model owns and
    cancels on teardown; it never blocks the menu. While `currentProfile` is
    nil the menu's online actions (items 3, 7, 8 will add them) are disabled
    and a one-line reason is published as `onlineUnavailableReason: String?`
    ("Signing in…" while pending, the `BackendError` case name mapped to plain
    copy on failure). Solo Practice and How to Play never wait on it.

    `signInAnonymously` exists only on the concrete `SupabaseBackend` and only
    in Debug. Declare a small `ShellSignIn` protocol in Shell with one
    `signIn() async throws -> Profile` requirement; `SupabaseBackend` conforms
    in an extension inside `#if DEBUG` in Shell, `FakeBackend` conforms in the
    test target. In Release the services value carries no sign-in and
    `currentProfile` stays nil.
  guardrails:
    - Exactly one `SupabaseBackend`, one `SystemAudioPlayer` and one `SettingsStore` exist per process; no screen constructs its own
    - Sign-in failure is a disabled state with a reason, never an alert, never a crash, never a retry loop
    - No `#if DEBUG` around any route or screen — only around the anonymous sign-in conformance itself
    - `Willagrams/Online/**` and `Willagrams/Audio/**` are consumed, not edited, in this item
  done when:
    - `ShellModel` built with a `FakeBackend` publishes a non-nil `currentProfile` after sign-in completes, and one built with a backend whose sign-in throws `.offline` publishes a nil profile and a non-empty `onlineUnavailableReason`
    - `startSoloPractice` succeeds while sign-in is still pending
    - A Release configuration compiles with no reference to `signInAnonymously` anywhere under `Willagrams/`
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  status: done

- task: |
    Let `MatchRun` run a match it did not build.

    `Willagrams/Shell/MatchRun.swift` constructs and owns a `SoloMatch` and
    reads its `session`, `dictionary` and `leave()`. Extract what it reads into
    a `MatchOpponent` protocol in Shell (`session: MatchSession`, `leave()`,
    the human-side `PlayerID`), make `SoloMatch` conform, and give `MatchRun`
    a second initializer that accepts an already-built opponent instead of a
    difficulty. `OnlineMatch` from `Willagrams/Online/OnlineMatch.swift` will
    be adapted to it in item 3 — this item only opens the seam.

    Teardown keeps the order round 2 established: the old opponent is down
    before a new one is built, and `ResultsModel`'s closures capture the
    opponent through the protocol.
  guardrails:
    - `SoloMatch` behavior does not change; `RematchTests` and `MatchRunTests` pass unmodified except for construction
    - `MatchRun` never learns which concrete opponent it holds — no `is`/`as?` on the opponent
    - Nothing under `Willagrams/Bot/**` or `Willagrams/Match/**` is edited
  done when:
    - A `MatchRun` built from a test-double `MatchOpponent` walks countdown → match → results the same way the solo path does, proven by the existing route-transition tests run against the double
    - Rematching three times through the solo path still leaves exactly one live match
    - `swift test --package-path Tests/ShellTests` passes
  status: done

- task: |
    Host a match from the menu and show the invite code.

    Add `AppRoute.hostLobby` and a `HostLobbyModel` in `Willagrams/Shell/`.
    The menu gains a "Play a Friend" action (enabled only when
    `currentProfile` is non-nil) that moves the route there. The model calls
    `OnlineMatch.host(options:backend:dictionary:dictionaryHash:...)` with the
    options `SettingsStore.load()` returns, then publishes `inviteCode`, the
    `lobby` roster as display names resolved through `profile(id:)`, and a
    `canStart` that is true exactly when `lobby.count == 2`. Start calls
    `start()`, wraps the `OnlineMatch` as a `MatchOpponent` (item 2), builds
    the `MatchRun`, and moves to `.countdown` carrying a `MatchSetup` derived
    from the session. Cancel calls `leave()` on the `OnlineMatch`, which
    abandons the row, and returns to the menu.

    `HostLobbyView` shows the code large, a system share sheet button for it,
    the roster, Start and Cancel. Pending states (creating, starting) are
    published on the model, never inferred in the view.
  guardrails:
    - The host is `roster[0]` as `OnlineMatch` elects it; shell never decides who hosts
    - Leaving the lobby always tears the `OnlineMatch` down before the route moves — no live channel survives a cancel
    - `OnlineMatchError` and `BackendError` surface as copy on the lobby screen, never as a crash or a silent return to the menu
    - Add `HostLobbyView.swift` to the `Shell` target's `exclude:` list in `Tests/ShellTests/Package.swift`
  done when:
    - With a `FakeBackend`, "Play a Friend" moves the route to `.hostLobby`, the model publishes a six-character code, and `canStart` flips true only after a second player is present
    - Start on a two-player lobby moves the route to `.countdown` and the resulting `MatchRun` holds a session whose `roster` has two players with the local player as host
    - Cancel from the lobby returns to `.menu` and the fake's match record reads `abandoned`
    - Live, on two simulators: the host's screen shows a code, and after the guest joins the host's roster shows the guest's display name
  after: online
  caution: false
  status: done  # all four criteria met; criterion 4 verified live on two simulators during item 4

- task: |
    Join a match by invite code.

    Add `AppRoute.join` and a `JoinModel` in `Willagrams/Shell/`. The menu's
    "Play a Friend" screen — or a second action beside it; keep it one screen
    with a code field if that reads cleaner — takes a six-character code,
    uppercases and trims it, and calls `OnlineMatch.join(code:backend:...)`.
    On success the model publishes a waiting state ("Waiting for host") with
    the host's display name, then awaits `awaitStart()`, wraps the
    `OnlineMatch` as a `MatchOpponent`, builds the `MatchRun`, and moves to
    `.countdown`. A wrong code (`BackendError.notFound`), a full or started
    match (`.matchFull`, `.permissionDenied`) and offline each map to a
    one-line message beside the field. Cancel while waiting calls `leave()`
    and returns to the menu.
  guardrails:
    - The code field accepts only `[A-Z0-9]`, length 6, before the join call is made — the backend regex is the last line, not the first
    - `awaitStart()` is cancelled when the player leaves; no orphaned task keeps a channel subscribed after the route moves
    - Add `JoinView.swift` to the `Shell` target's `exclude:` list
  done when:
    - With a `FakeBackend` holding a lobby, entering its code moves the model to the waiting state, and the fake's `match_players` shows the joiner
    - A code that matches no match publishes a not-found message and the route stays put
    - When the fake host starts, the guest's route moves to `.countdown` with a `MatchRun` whose session names the host as `roster[0]` and the local player as guest
    - Live, on two simulators: the guest enters the host's code and reaches the match screen when the host presses Start
  after: online
  caution: false
  status: done

- task: |
    Show reconnecting, end on gone, and give online results a way home.

    `MatchHUDModel` already reads `session.peerPresence` to gate Draw and win.
    Add a published `overlay: MatchOverlay?` on the match-side model (`.reconnecting(name)` while any peer's `presence(of:)` is `.reconnecting`, nil otherwise) and a `ReconnectingOverlay` view in `MatchView` that dims the board and names the peer, matching design comp 10's intent (`docs/design/README.md`) without new data. Input is locked while the overlay shows — `BoardView` already takes `inputLocked`. When `session.isMatchOver` becomes true because a peer went `.gone`, `endWhenTheMatchDoes` (already armed in `ShellModel`) carries the route to results as it does for a win; `ResultsModel` names the outcome ("Opponent left") rather than a winner when `state.winner` is nil.

    For an online opponent `ResultsModel` offers Main Menu only: the rematch
    action is absent, not disabled. Solo results are unchanged.
  guardrails:
    - No state is added to `MatchSession`; presence is read, never stored again in Shell
    - The overlay never appears in a solo match — `BotMatch`'s peer is never `.reconnecting`
    - The outcome recorder attached by `OnlineMatch` is not touched; results reads what the session already finished with
  done when:
    - With a test-double session reporting a peer `.reconnecting`, the model publishes the overlay and `inputLocked` is true; when the peer returns `.present` both clear
    - With the peer `.gone`, the route moves to `.results` and the results model's headline names a departed opponent, not a winner
    - `ResultsModel` built for an online opponent exposes no rematch action; built for solo it still does
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  status: done  # all four criteria met; overlay lives on MatchBoard (MatchHUDModel carries a fence banning peerPlayerID)

- task: |
    Present the settings lane's options view and persist the choice.

    `Willagrams/Shell/SoloSetupView.swift` hand-rolls Toggle and Stepper rows
    for the same options `Willagrams/Settings/Views/MatchOptionsView.swift`
    renders from a `MatchOptionsForm` binding, and
    `Willagrams/Settings/Model/SettingsStore.swift` (`load()`, `save(_:)`) has
    no caller in the app. `SoloSetup` holds a `MatchOptionsForm` loaded from
    the injected `SettingsStore` on entry and saved on Start; `SoloSetupView`
    embeds `MatchOptionsView(form:)` in place of its own rows. The difficulty
    choice stays shell's. `HostLobbyModel` (item 3) reads the same store, so a
    host's rules are the ones last chosen for solo.
  guardrails:
    - `Willagrams/Settings/**` is consumed, not edited — the form and the view are used as they ship
    - The bot difficulty control remains shell's own list from `BotDifficultyMenu.choices`; no second options UI exists under `Willagrams/Shell/**`
    - `MatchOptions.validated` still runs on whatever the form produces before it reaches a match
  done when:
    - Changing an option in solo setup, starting, and rebuilding `ShellModel` on the same `UserDefaults` suite loads the changed option
    - The `MatchSetup` handed to `.countdown` from solo setup carries the form's options, and item 3's lobby creates its match with the same options
    - No Toggle or Stepper over a match option remains under `Willagrams/Shell/**`
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  after: settings
  status: not started

- task: |
    The profile screen.

    Create `Willagrams/Account/` with `ProfileModel` (observable: the
    `Profile`, an `isEditable` flag, a display-name draft, `save()` through
    `updateDisplayName`, the four stats as labelled rows via `StatRow` from
    Style, the friend code with copy and share actions) and `ProfileView`.
    Create `Tests/AccountTests/` as its own SwiftPM package on the OnlineTests
    layout (symlinks to Account, Online and Match; excludes the View; carries a
    `SourceGuardrailTests` on the ShellTests pattern). Shell adds
    `AppRoute.profile` and a menu action "Profile", enabled when
    `currentProfile` is non-nil, rendering `ProfileView` for the local player
    with editing on. The route returns to the menu.

    The name field clamps to 1–24 characters client-side, matching the column
    check, before `updateDisplayName` is called.
  guardrails:
    - `Willagrams/Account/**` holds no navigation — shell owns the route; the screen reports back through closures
    - No stat is computed client-side; every number is the `Profile` row as read
    - The screen renders for any `Profile`, not only the local one — item 9 reuses it read-only
    - Add `ProfileView.swift` to the new package's `exclude:` list and register the package's literal `swift test` command in this file's Global rules when it exists
  done when:
    - `ProfileModel` on a `FakeBackend` saves a new name and re-reads it; a 25-character draft is refused before any call is made
    - The menu's Profile action moves the route to `.profile` and back
    - `swift test --package-path Tests/AccountTests` exists and passes, and the iOS `xcodebuild` build passes
  status: not started
  parallel-group: a

- task: |
    The friends list.

    Create `Willagrams/Friends/` with `FriendsModel` (observable: loads
    `friendships()`, resolves each counterpart's `Profile` through
    `profile(id:)`, and publishes three sections — accepted, incoming pending,
    outgoing pending; `accept(_:)` and `decline(_:)` call
    `respondToFriendRequest(requesterID:accept:)`, `block(_:)` calls `block`)
    and `FriendsView`. Create `Tests/FriendsTests/` on the same package layout
    as item 7. Shell adds `AppRoute.friends` and a menu action "Friends",
    enabled when `currentProfile` is non-nil. Blocked players are hidden from
    every section.

    Live-gated cases in FriendsTests create two anonymous users through
    `SupabaseBackend.signInAnonymously()` on two backends, run request →
    accept → list on each side, and assert both lists show the other. This is
    the RLS proof; the `FakeBackend` cases cover the model's sectioning only.
  guardrails:
    - Friends is tested against the real database — a run with the live gate skipped does not satisfy this item
    - The model never writes to `friendships` except through the three seam calls; no client-side status arithmetic
    - `rls_behavior.sql` is not edited by this item — a policy the live case shows to be wrong is a `/foundation` amendment, reported not fixed
    - Add `FriendsView.swift` to the new package's `exclude:` list
  done when:
    - On a `FakeBackend` seeded with one accepted, one incoming and one outgoing friendship, the model publishes each in its own section, and accepting the incoming one moves it to accepted
    - Live: two fresh anonymous users request and accept, and each side's `FriendsModel` lists the other as accepted; a blocked user appears in neither list
    - `swift test --package-path Tests/FriendsTests` passes with `WILLAGRAMS_LIVE_TESTS=1`, and the iOS `xcodebuild` build passes
  caution: true
  status: not started
  parallel-group: a

- task: |
    Add a friend by code, and open a friend's profile.

    `FriendsModel` gains `lookup(code:)` → `profile(friendCode:)` and
    `request(_:)` → `requestFriend(addresseeID:)`; `FriendsView` gains a code
    field with the same `[A-Z0-9]{8}` client-side clamp the backend enforces
    and a result row with a Request button. `.alreadyExists` and `.blocked`
    map to one-line copy. Tapping an accepted friend moves shell's route to
    `.profile` for that player with `isEditable` false, reusing item 7's
    screen unchanged; Back returns to the friends list, not the menu.
  guardrails:
    - A player cannot request themself — the model refuses its own code before any call
    - `ProfileView` is reused, never copied, for the read-only case
    - Add no new View file without its `exclude:` entry
  done when:
    - On a `FakeBackend` with a seeded profile, looking up its code publishes that profile, and requesting it creates a pending outgoing friendship in the list
    - Looking up the local player's own code publishes a refusal and makes no backend call
    - Tapping an accepted friend moves the route to a read-only profile whose stats are that friend's row, and Back returns to `.friends`
  status: not started

- task: |
    Invite a friend to play, in-app.

    Add a per-user invite channel to `Willagrams/Online/`: `MatchInviteChannel`
    subscribes to a Realtime broadcast channel named for the local user id at
    sign-in and publishes an `AsyncStream<MatchInvite>` (`matchID`,
    `inviteCode`, `hostID`, `hostName`, `sentAt`); `send(_:to:)` broadcasts to
    the recipient's channel. Model it on `SupabaseMatchChannel` and its stub,
    including the frame-under-`payload` decode the first live run had to fix.
    Extend `FakeBackend`'s transport factory pattern with an in-memory invite
    bus so the offline suite can run two users.

    Shell: an accepted friend row gains "Invite to play". Tapping it runs item
    3's host flow and, once the code exists, sends the invite. The recipient's
    `ShellModel` consumes the stream from item 1's services: an invite arriving
    on the menu, friends, profile or join screens publishes a banner ("<name>
    wants to play") with Join, which runs item 4's join with that code;
    arriving during a match or a lobby it is dropped. A banner older than two
    minutes, or whose join fails with `.notFound` / `.permissionDenied`, clears
    with a one-line "That game is over".
  guardrails:
    - No migration — invites are broadcast only, never stored; `supabase/migrations/**` stays untouched
    - `Willagrams/Online/BackendContracts.swift` is `protected:` — the invite channel is a new type beside the seam, not a change to it
    - Only accepted friends can be invited; the send button never renders on a pending row
    - A double tap sends at most one invite for one lobby; the recipient shows at most one banner per `matchID`
    - The subscription is torn down on sign-out and on `ShellModel` teardown; no channel outlives the model
  done when:
    - Offline, two `ShellModel`s on the fake bus: inviting from A publishes exactly one banner on B naming A; B's Join moves B to item 4's waiting state on A's code; a second tap on A adds no second banner
    - An invite arriving while B is on `.match` publishes nothing; one arriving with `sentAt` older than two minutes publishes nothing
    - Joining a banner whose lobby was cancelled clears it with the "over" message and B stays on the menu
    - Live, on two simulators signed in as friends: A taps Invite, B's banner appears within five seconds, B joins, A starts, and both reach the match screen
  after: online
  caution: true
  status: not started

- task: |
    Give every sound cue a call site.

    All nine `SoundEffect` cases through item 1's injected player, from the
    model that owns each moment: `countdownTick` per second in
    `CountdownOverlay`; `draw` and `swap` on a granted request in
    `MatchHUDModel`; `invalid` where `refuse()` counts a refused Draw or win;
    `win` and `loss` when `ResultsModel` resolves the outcome; `menuTap` from
    each `ShellModel` menu transition (`showSoloSetup`, `showHowToPlay`, and
    the actions items 3, 7, 8 added); `tilePlace` and `tileRecall` from
    `MatchBoard`'s commit bridge, which is the one place shell sees a tile
    land on or leave the table. Haptics stay where they are —
    `BoardHaptics` fires directly and `AudioPlayer.impact` is not called for
    tiles; call `impact(.medium)` on `win` only.
  guardrails:
    - Cues are played from models and the commit bridge, never from a View body or `onChange` — the test for each is the recording player in ShellTests
    - `Willagrams/Board/**` and `Willagrams/Audio/**` are not edited; the bridge in `Willagrams/Shell/MatchBoard.swift` is the seam
    - A drag that does not commit plays nothing; a swap plays `swap`, never `tileRecall` plus `draw`
    - Never introduce a `Task` or `await` around a cue
  done when:
    - With a recording `AudioPlayer`, a solo match that deals, places one tile, draws once, recalls one tile and wins records exactly `tilePlace`, `draw`, `tileRecall`, `win` for those moments in that order, with `countdownTick` once per countdown second before them
    - A refused Draw records `invalid` and no `draw`; a swap records one `swap`
    - Each menu action records one `menuTap`
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  after: audio
  status: not started

- task: |
    The mute control.

    A speaker toggle on the menu, in `MenuView`, bound to a published
    `isMuted` on `ShellModel` that reads `AudioSettings.isMuted` at init and
    on change calls both `AudioSettings.setMuted(_:)` and the injected
    player's `setMuted(_:)`. Label it from a local constant per the chrome
    rule; VoiceOver reads "Sound on" / "Sound off".
  guardrails:
    - Mute is sound only; haptics are not touched, per MAP's "Decided" section on audio
    - The two writes (settings and player) happen together — no path sets one without the other
  done when:
    - Toggling mute, then rebuilding `ShellModel` on the same `UserDefaults` suite, publishes `isMuted == true` and the freshly injected player was constructed muted
    - With the recording player, toggling mute calls `setMuted(true)` on it, and `menuTap` is still recorded while muted (the player, not the model, decides silence)
  after: audio
  status: not started

> **⚠️ AUTONOMOUS RUN — STOP HERE**

> The item below waits on the paid Apple Developer membership. Nothing under
> the marker runs unattended; resume once `com.apple.developer.applesignin`
> is in `Willagrams.entitlements` (a Reviewer edit) and `online` has
> implemented `signInWithApple`.

- task: |
    Sign in with Apple.

    A sign-in screen in `Willagrams/Account/` that runs
    `ASAuthorizationAppleIDProvider` with a hashed nonce and calls
    `signInWithApple(idToken:nonce:)`; shell routes to it when no session
    exists in Release and links an existing anonymous identity in Debug.
  guardrails:
    - Never ship a Release build that can create an anonymous session
    - The nonce is generated per attempt and never logged
  done when:
    - A Release build with no session shows the sign-in screen first and reaches the menu after a successful sign-in
    - Signing in on a device that previously played anonymously keeps its profile row
  status: not started
