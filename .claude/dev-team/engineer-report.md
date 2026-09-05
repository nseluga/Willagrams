# Engineer Report
**Task:** LANE.md item 3 — host a match from the menu and show the invite code
**Branch:** auto/shell-r3 (in place, no worktree)
**Date:** 2026-09-04

## Gates
- `swift test --package-path Tests/ShellTests` — 141 passed, 0 failed, 0 skipped (baseline 135 + 6 new)
- `swift test` — 53 passed, 0 failed
- `swift test --package-path Tests/MatchTests` — 125 passed, 0 failed
- `swift test --package-path Tests/OnlineTests` — 126 passed, 0 failed, 1 pre-existing known issue
- `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` — ** BUILD SUCCEEDED **

## done when
1. `HostLobbyTests."Play a Friend opens a lobby, shows a six-character code, and waits for a second player"` — PASS
2. `HostLobbyTests."Start on a two-player lobby moves to the countdown over a two-player session"` — PASS
3. `HostLobbyTests."Cancel leaves the channel, abandons the row and returns to the menu"` — PASS
4. UNVERIFIED. Not attempted on two simulators: nothing in `Willagrams/` calls `OnlineMatch.join` — the guest has no way into a lobby until item 4 ships the join screen, so a second simulator cannot join the host's code through the app. `grep -rn "OnlineMatch.join" Willagrams/` returns nothing.

## Files Changed
- `Willagrams/Shell/HostLobbyModel.swift` (new) — the lobby's whole state machine: create, roster+names, Start, Cancel, `Phase`, static error copy
- `Willagrams/Shell/HostLobbyView.swift` (new) — code at display size, `ShareLink`, roster, Start/Cancel; branches only on published values
- `Willagrams/Shell/OnlineOpponent.swift` (new) — wraps `OnlineMatch`+`MatchSession` as a `MatchOpponent`; never touches `MatchRun.match`
- `Willagrams/Shell/AppRoute.swift` — `case hostLobby`, carrying nothing
- `Willagrams/Shell/ShellModel.swift` — `hostLobby`, `canPlayOnline`, `playAFriend()`; `returnToMenu()` tears the lobby down before moving the route
- `Willagrams/Shell/MenuView.swift` — "Play a Friend", disabled without a profile, reason underneath
- `Willagrams/Shell/ShellRootView.swift` — renders the lobby when one exists
- `Willagrams/Online/OnlineMatch.swift` — added `MatchAbandoning`, `leave()` (pump/recorder cancel, transport leave, abandon the row only if never started), `hasStarted`; fenced the `SupabaseBackend` default on `canImport(PostgREST)` so the file builds SDK-free
- `Willagrams/Online/FakeBackend.swift` — conforms to `MatchAbandoning`
- `Willagrams/Online/SupabaseBackend+Matches.swift` — `abandon(matchID:)`, an update fenced on `status = lobby`
- `Tests/ShellTests/Package.swift` — `Match` target now compiles `OnlineMatch.swift`/`MatchOutcomeRecorder.swift`; `HostLobbyView.swift` added to the `Shell` exclude
- `Tests/ShellTests/Cases/HostLobbyTests.swift` (new) — 6 cases over a `LobbyWire` double (`FakeTransport.pair` buffers `.connected` immediately, so it cannot falsify `canStart`)

## Design Decisions
- Teardown lives only in `ShellModel.returnToMenu()`, so every exit — not just Cancel — leaves the façade before the route moves
- `start()` nils `self.match` before calling `startMatch`, so the shell's own pass through the menu cannot kill the match it is opening
- `hasStarted` decides abandon-vs-leave: a lobby nobody played abandons its row; a match that ran belongs to the outcome recorder
- `MatchAbandoning` is a new protocol because `BackendContracts.swift` is protected; two real conformers, not a one-implementation abstraction
- Lazier alternative not taken: leave the row in `lobby` forever and let a server sweep expire it — no client protocol, no Supabase update, but abandoned lobbies stay joinable until the sweep

## Flags for Reviewer
- `resolveNames` reads `profile(id:)` one player at a time and is skipped while a read is in flight; fine at two players, unbounded shape if the roster ever grows
- `OnlineMatch.leave()` fires the abandon as a detached `Task` with `try?` — a failed abandon is silent and the row stays `lobby`
- `abandon(matchID:)` relies on RLS + `.eq("status", "lobby")` for correctness; it cannot report that it matched zero rows
- Criterion-2's test injects a 500ms `sleepFor` so the countdown is still live when the route is read; it tears down explicitly at the end
