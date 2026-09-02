# Willagrams — online lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

**Current position**
- Status: in progress — autonomous run started 2026-09-01
- Next: item 7 — wiring: a whole match over the live project
- Blockers: no Supabase anon key is reachable this session, so every
  `WILLAGRAMS_LIVE_TESTS` criterion is written and gated but not yet executed
  against the real project. A live verification pass is owed.
- Last updated: 2026-09-02

| Item | Status |
|------|--------|
| 1 — the concrete Supabase client and its session | done — the app can now talk to the real Willagrams database: it signs a player in, creates their profile with an eight-character friend code the first time, and turns database errors into the app's own error list. The checks that need a live database are written but not yet run. |
| 2 — friendships on the real client | done — players can now send, accept, decline and block friend requests against the real database, with one record per pair and a decline stored as a block. The checks that need a live database are written but not yet run. |
| 3 — matches on the real client | done — a player can now open a match on the real database and hand out a six-character invite code, and a friend can join with it. Joining goes through the database's own guarded join, never a lookup by code. The checks that need a live database are written but not yet run. |
| 4 — the realtime transport | done — the transport speaks over a real Supabase channel; everything about how messages queue, replay and stop was proven without a server, and the one criterion needing two live players is owed |
| 5 — recording the match outcome | done — when a match ends, the result is written down: the match row closes with a winner and times, and each player's own record gains a game played, a win if they won, tiles placed, and a best-win time. Written once per match, never decremented. The checks that need a live database are written but not yet run. |
| 6 — the OnlineMatch façade | done — one object now stands up an online match end to end: a creator opens a lobby and gets an invite code, a friend joins with it, each side watches the other appear, and starting the match hands both players a session with the same tiles in the same order. Whichever of the two sorts first serves the tile pool, so it works the same no matter who created the match, and starting with nobody there refuses and leaves the match untouched. The checks that need two live players are written but not yet run. |
| 7 — wiring: a whole match over the live project | not started |
| 8 — real Sign in with Apple (below the stop marker) | not started |
