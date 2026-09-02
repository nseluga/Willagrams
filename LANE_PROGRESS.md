# Willagrams — online lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

**Current position**
- Status: autonomous run complete — items 1-7 all done, 2026-09-02. Item 8 sits
  below the stop marker and was deliberately not run.
- Next: the live verification pass, which is blocked on one thing — see below.
- Blockers: **the anon key.** `SupabaseConfig.anonKey` currently reads
  `SUPABASE_ANON_KEY` from the environment and falls back to an empty string, so
  no key was reachable this session and none would be present on a device either.
  Every `WILLAGRAMS_LIVE_TESTS` criterion is written against the real API and
  proven to fire (forcing the gate with a junk key returns a real HTTP 401 from
  the project), but none has been executed for real. Two things are owed before
  `online` is called from any screen:
  1. Give `SupabaseConfig` a real anon key that survives into a Release build —
     a literal constant or an Info.plist/xcconfig value, with the environment
     variable kept only as a test override. Until this lands, even a manual run
     on a device cannot reach the project.
  2. Run the whole OnlineTests package once with
     `WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=... swift test --package-path Tests/OnlineTests`
     and confirm the 22 skipped cases go green.
- Also owed, found by the lane acceptance review: profile stats are written as a
  blind read-modify-write, so two matches finishing at once on one account lose
  an increment. The fix is a Postgres-side increment, which means a `/foundation`
  amendment — migrations are protected and this lane may not make it.
- Last updated: 2026-09-02

| Item | Status |
|------|--------|
| 1 — the concrete Supabase client and its session | done — the app can now talk to the real Willagrams database: it signs a player in, creates their profile with an eight-character friend code the first time, and turns database errors into the app's own error list. The checks that need a live database are written but not yet run. |
| 2 — friendships on the real client | done — players can now send, accept, decline and block friend requests against the real database, with one record per pair and a decline stored as a block. The checks that need a live database are written but not yet run. |
| 3 — matches on the real client | done — a player can now open a match on the real database and hand out a six-character invite code, and a friend can join with it. Joining goes through the database's own guarded join, never a lookup by code. The checks that need a live database are written but not yet run. |
| 4 — the realtime transport | done — the transport speaks over a real Supabase channel; everything about how messages queue, replay and stop was proven without a server, and the one criterion needing two live players is owed |
| 5 — recording the match outcome | done — when a match ends, the result is written down: the match row closes with a winner and times, and each player's own record gains a game played, a win if they won, tiles placed, and a best-win time. Written once per match, never decremented. The checks that need a live database are written but not yet run. |
| 6 — the OnlineMatch façade | done — one object now stands up an online match end to end: a creator opens a lobby and gets an invite code, a friend joins with it, each side watches the other appear, and starting the match hands both players a session with the same tiles in the same order. Whichever of the two sorts first serves the tile pool, so it works the same no matter who created the match, and starting with nobody there refuses and leaves the match untouched. The checks that need two live players are written but not yet run. |
| 7 — wiring: a whole match over the live project | done — there is now one test that plays a whole match the way two real players would: two accounts, one hosts and one joins, both draw tiles through the connection, one wins, and the result is written down. It runs for real against the live database when a key is available; without one it is skipped, and an offline twin of the same script runs every time so the match logic is still checked. |
| 8 — real Sign in with Apple (below the stop marker) | not started |

## Run close-out — 2026-09-02

Seven items done, none blocked, in one unattended `/dev-team-auto` run. Item 8
(real Sign in with Apple) sits below the stop marker and was not touched; it
still waits on the Apple Developer membership.

**Full suite, all nine packages, on the merged lane branch:** engine 53, Board
253, Match 125, Style 30, Shell 125, Settings 36, Bot 68, Online 124, Audio 19 —
and `xcodebuild` BUILD SUCCEEDED. The first Bot run reported one issue; BotTests
passed 68/68 on two consecutive re-runs and this lane touches no file under
`Willagrams/Bot/**`, so that is a flake in a timing-sensitive pacing test, not a
regression. Online grew 26 → 124, of which 22 are the gated live cases.

**Lane acceptance review:** no criterion unmet and no guardrail violated. Of the
25 `done when:` criteria across items 1-7, 12 are met by tests that execute, 4
have their offline half executed and their live half deferred, and 9 are
deferred-live. The reviewer's judgement was that the deferral is honest rather
than papered over: items 5, 6 and 7 share the same assertion functions between
their live and offline forms, so the rules are checked on every run and the live
pass confirms that real PostgREST and Realtime behave as the doubles claim.

**What was proven without a server.** Every item extracted an offline core and
mutation-checked it — the check's own condition broken, the suite confirmed red,
the file restored from a copy. 66 mutation checks across the seven items, all
caught by a named test. The one item that needed two attempts was the façade:
its first version was green with 9 of 9 mutations caught and still dead-locked
about half of all real pairings, because every test happened to order its player
ids the favourable way.
