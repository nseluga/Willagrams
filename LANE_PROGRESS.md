# Bot lane — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** round 2 in progress — 3 of 6 items done.
- **Next:** item 4 — the two expensive rungs and the stall floor (flagged for extra scrutiny).
- **Blockers:** none.
- **Last updated:** 2026-08-19

## Round 2 — a guest that plays, on a transport that ships

| Item | Status |
|------|--------|
| Build the shipping in-memory transport and its test package | done — The bot now has a real in-memory connection to the player that works in a shipping build, not just in debug. |
| Build the bot's end of the wire — connected, dealt to, playing nothing | done — The bot now joins a match as a second player and receives its opening tiles; it does not play them yet. |
| Give the bot a difficulty model and a brain that plays the simplest way | done — The bot now actually plays: it takes its tiles, builds a valid connected board one tile at a time, draws when it runs out, and only calls a win it has genuinely earned. |
| Add the two expensive rungs, and a stall floor | not started |
| Add the last rung: give a tile back | not started |
| Build the difficulty screen | not started |
