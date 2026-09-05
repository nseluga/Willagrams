# Engineer Report
**Task:** LANE.md item 2 — let `MatchRun` run a match it did not build (`MatchOpponent` seam)
**Branch:** auto/shell-r3
**Date:** 2026-09-04
**severity:** none — no blocked path, no amendment needed

## Design Decisions
- `MatchOpponent` is class-bound and carries `session`, `localPlayerID`, `start()`, `leave()`; `start()` is included because `MatchRun.start()` must drive the far end without a cast.
- `localPlayerID` has a protocol-extension default of `session.localPlayerID`, so `SoloMatch` conforms with an empty extension and gains no member.
- `MatchRun` stores `let opponent: any MatchOpponent`; `session`, `start()`, `leave()` all route through it.
- KNOWN TENSION resolved with `public private(set) var match: SoloMatch!` set only by the solo initializer — never by a cast. Optional-chained `run?.match` still yields `SoloMatch?`, so **zero test edits**: `RematchTests`, `MatchRunTests`, `SoloMatchTests`, `SoloSetupTests`, `ShellModelTests` compile and pass unmodified (not even construction). Trap-on-nil is deliberate: reading `.match` on a non-solo run is a bug, not a nil to pass along.
- The solo init is now a `convenience` that builds `SoloMatch` and delegates to the opponent init, so there is one assembly path.
- `ShellModel.startMatch(_:opponent:)` takes the opponent as a **closure**, not a value: a value argument would be constructed before the call is entered, i.e. before teardown. Item 3/4 call it as `startMatch(setup) { OnlineOpponent(match) }`.
- Both start paths share a new private `install(_:)` that arms the trackers and opens the run, so solo and online cannot arm different things.

## Files Changed
- `Willagrams/Shell/MatchOpponent.swift` — new: the protocol, the `localPlayerID` default, `extension SoloMatch: MatchOpponent {}`. Pure state, no exclude entry needed.
- `Willagrams/Shell/MatchRun.swift` — holds `opponent`; `match` became `SoloMatch!` set by the solo convenience init; second (designated) init takes a built opponent.
- `Willagrams/Shell/ShellModel.swift` — added `startMatch(_:opponent:)` and private `install(_:)`; `startSoloPractice` unchanged in behavior, tail moved into `install`.
- `Tests/ShellTests/Cases/MatchOpponentTests.swift` — new: 4 cases (route walk on a double, teardown order, solo path tears the double down first, falsifiable no-cast source scan).

## Verification
- `swift test --package-path Tests/ShellTests` → **135** (floor 131). Root **53**, MatchTests **125**, BotTests **68**, `xcodebuild … build` **BUILD SUCCEEDED**. Zero failures.
- Mutation A (build the opponent before `returnToMenu()`): ordering test went RED — `["build A","build B","leave A"]`. Restored.
- Mutation B (respelled `opponent.leave()` to a local): the source scan went RED. Restored.

## Deferred / Out of Scope
- No `OnlineMatch` adapter — item 3.
- `ResultsModel`'s closures still go through `ShellModel` (no concrete type reaches them); removing rematch for an online opponent is item 5.

## Flags for Reviewer
- `MatchRun.match` is an IUO: any future non-solo caller that reads it traps. Only tests read it today.
- `startMatch(_:opponent:)` bumps `generation` twice per start (`returnToMenu` + `install`), same as `startSoloPractice` — stale results screens decline, as designed.
