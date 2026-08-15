# Willagrams — Lane: match — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** autonomous run in progress
- **Next:** Build host authority over the pool (HostPool.swift)
- **Blockers:** none
- **Last updated:** 2026-08-14

## Round 1 — the match lane

| Item | Status |
|------|--------|
| Define the transport seam (MatchTransport + FakeTransport) | in progress |
| Build the wire codec (MatchCodec) | done — Two devices can now turn match messages into bytes and back, and a match from an app version that speaks a different wire format is refused instead of played. |
| Build host authority over the pool (HostPool) | not started |
| Build the client-side match state machine (MatchSession) | not started |
| Build the terminal states — win, resign, peer-disconnect freeze | not started |
| Wrap Game Center sign-in (GameCenterAuth) | skipped — below stop marker |
| Conform GKMatch to the transport (GKMatchTransport) | skipped — below stop marker |
| Implement the real reconnect attempt behind the freeze | skipped — below stop marker |
