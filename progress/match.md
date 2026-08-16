# Willagrams — Lane: match — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

The style lane's ledger previously sat at this path; it has been archived to
`progress/style.md` per the archive rule, since every lane writes this filename.

## Current position

- **Status:** autonomous run complete — stopped at the stop marker, all five
  pre-marker items done
- **Next:** Wrap Game Center sign-in (GameCenterAuth) — below the stop marker,
  needs two physical iOS devices and two Game Center accounts
- **Blockers:** none for this lane. Items 6-8 are gated on real hardware, not on code.
- **Last updated:** 2026-08-15

## Round 1 — the match lane

| Item | Status |
|------|--------|
| Define the transport seam (MatchTransport + FakeTransport) | done — The app now has one agreed way for two players' devices to pass messages, plus a stand-in version that lets the whole match be tested on one machine with no second device and no Game Center account. |
| Build the wire codec (MatchCodec) | done — Two devices can now turn match messages into bytes and back, and a match from an app version that speaks a different wire format is refused instead of played. |
| Build host authority over the pool (HostPool) | done — One device now owns the real tile pool and answers both players' requests from it, so a draw gives each player exactly one tile, a swap with too few tiles left is refused without disturbing the pool, and the two devices agree on which one is in charge without negotiating. |
| Build the client-side match state machine (MatchSession) | done — The match now runs on each player's device: it counts down to the start, applies tiles as they arrive, and when the opponent draws it holds the new tile until the player presses Draw, keeping the board locked until they do so both players take a tile for the same event. |
| Build the terminal states — win, resign, peer-disconnect freeze | done — A match can now actually end: a player wins or resigns and both devices agree who won, and if the opponent's connection drops the board locks and a countdown runs, so the match waits for them instead of ending in confusion — and if they never come back it ends with nobody named the winner. |
| Wrap Game Center sign-in (GameCenterAuth) | skipped — below stop marker |
| Conform GKMatch to the transport (GKMatchTransport) | skipped — below stop marker |
| Implement the real reconnect attempt behind the freeze | skipped — below stop marker |
