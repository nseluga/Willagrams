# Willagrams — Lane: match — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

The style lane's ledger previously sat at this path; it has been archived to
`progress/style.md` per the archive rule, since every lane writes this filename.

## Current position

- **Status:** autonomous run in progress
- **Next:** Build the client-side match state machine (MatchSession.swift)
- **Blockers:** none
- **Last updated:** 2026-08-15

## Round 1 — the match lane

| Item | Status |
|------|--------|
| Define the transport seam (MatchTransport + FakeTransport) | done — The app now has one agreed way for two players' devices to pass messages, plus a stand-in version that lets the whole match be tested on one machine with no second device and no Game Center account. |
| Build the wire codec (MatchCodec) | done — Two devices can now turn match messages into bytes and back, and a match from an app version that speaks a different wire format is refused instead of played. |
| Build host authority over the pool (HostPool) | done — One device now owns the real tile pool and answers both players' requests from it, so a draw gives each player exactly one tile, a swap with too few tiles left is refused without disturbing the pool, and the two devices agree on which one is in charge without negotiating. |
| Build the client-side match state machine (MatchSession) | not started |
| Build the terminal states — win, resign, peer-disconnect freeze | not started |
| Wrap Game Center sign-in (GameCenterAuth) | skipped — below stop marker |
| Conform GKMatch to the transport (GKMatchTransport) | skipped — below stop marker |
| Implement the real reconnect attempt behind the freeze | skipped — below stop marker |
