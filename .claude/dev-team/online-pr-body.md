# online lane — round 2

The backend seam that replaces GameKit: hosted client, session, database
access, and the MatchTransport adapter over a realtime channel.

**Live verification is owed.** The Supabase project `ynkayuwwrifluhhqnrjc` is
healthy, but no anon key was reachable during the autonomous run, so every
`WILLAGRAMS_LIVE_TESTS` case is written against the real API and reports as
skipped. Run the suite once with `WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=…`
before merging.

## Team memory entries (append to `.claude/dev-team/team-memory.md` in merge order)

## 2026-09-02 00:05 — dev-team-auto — online item 1: concrete Supabase client + session
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus/medium) — branch `item/online-client`, merged into `lane/online` at `e061e4a`
- **What happened:** Built `SupabaseBackend` (actor, `BackendClient`) + `SupabaseConfig` + the `WILLAGRAMS_LIVE_TESTS` gate and 5 live cases. Converged in one engineer pass; the orchestrator mutation-checked all 12 guards itself. Live criteria 1–3 deferred — no anon key is reachable in this session, so the live cases are written for real but report as skipped.
- **What worked:** Factoring the three offline-provable pieces out as pure statics (`friendCodeAlphabet`, `randomFriendCode()`, `backendError(from:hasSession:)`, `firstProfile(fromRows:)`) — named in the spawn prompt as a testability requirement — made every guard mutable and every mutation red without a single injectable-fetch abstraction. Forcing `LiveProject.isEnabled` to `true` is the cheap proof that skipped live cases are real: they returned a genuine 401 from the project URL rather than passing.
- **What failed:** none.
- **Remember next run:** `Tests/OnlineTests` is no longer SDK-free — it now pins `supabase-swift` `exact: "2.55.1"` and links Auth/PostgREST/Realtime, because `Willagrams/Online/**` is symlinked in whole. Any future `AccountTests`/`FriendsTests` package that symlinks `Willagrams/Online` inherits the same dependency and the same multi-minute first build; that is a consequence of LANE.md's file layout, not of this item. There is no `Supabase` umbrella product in the xcodeproj (only Auth/PostgREST/Realtime), so `SupabaseClient` does not exist in this codebase — compose the three clients over one token source instead. `SupabaseConfig.anonKey` reads `SUPABASE_ANON_KEY` from the environment, so every live run needs `WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=... swift test --package-path Tests/OnlineTests`. `supabase projects api-keys` is blocked by the permission classifier — get the key from the dashboard or an `.env` before promising a live verification pass. New offline gate baseline for items 2–7: 41 tests, 4 suites, 36 passed, 5 skipped.
- **Worktree naming (lane-level, found at preflight):** SwiftPM derives package identity from the directory name, and `Tests/OnlineTests/Package.swift` depends on `.package(path: "../..")`. Any worktree whose last path component is not literally `Willagrams` fails to resolve. Create item worktrees as `<dir>/Willagrams`.
