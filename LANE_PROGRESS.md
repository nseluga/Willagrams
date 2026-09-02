# Willagrams — online lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

**Current position**
- Status: in progress — autonomous run started 2026-09-01
- Next: item 2 (friendships) and item 3 (matches), parallel group b
- Blockers: no Supabase anon key is reachable this session, so every
  `WILLAGRAMS_LIVE_TESTS` criterion is written and gated but not yet executed
  against the real project. A live verification pass is owed.
- Last updated: 2026-09-02

| Item | Status |
|------|--------|
| 1 — the concrete Supabase client and its session | done — the app can now talk to the real Willagrams database: it signs a player in, creates their profile with an eight-character friend code the first time, and turns database errors into the app's own error list. The checks that need a live database are written but not yet run. |
| 2 — friendships on the real client | not started |
| 3 — matches on the real client | not started |
| 4 — the realtime transport | not started |
| 5 — recording the match outcome | not started |
| 6 — the OnlineMatch façade | not started |
| 7 — wiring: a whole match over the live project | not started |
| 8 — real Sign in with Apple (below the stop marker) | not started |
