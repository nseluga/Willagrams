# Bot lane — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** round 2 complete — 6 of 6 items done.
- **Next:** none in this round. Lane is ready for review and merge.
- **Blockers:** none.
- **Last updated:** 2026-08-20

## Round 2 — a guest that plays, on a transport that ships

| Item | Status |
|------|--------|
| Build the shipping in-memory transport and its test package | done — The bot now has a real in-memory connection to the player that works in a shipping build, not just in debug. |
| Build the bot's end of the wire — connected, dealt to, playing nothing | done — The bot now joins a match as a second player and receives its opening tiles; it does not play them yet. |
| Give the bot a difficulty model and a brain that plays the simplest way | done — The bot now actually plays: it takes its tiles, builds a valid connected board one tile at a time, draws when it runs out, and only calls a win it has genuinely earned. |
| Add the two expensive rungs, and a stall floor | done — When no single tile fits, the bot now pulls back part of its board and rebuilds, and an easy bot that keeps getting stuck is given one harder attempt so it can never stall the match forever. |
| Add the last rung: give a tile back | done — A hard bot that is truly stuck now hands one useless tile back for a fresh one, and stops asking for good once the host says no. |
| Build the difficulty screen | done — There is now a screen offering Easy, Medium and Hard, which reports the choice back and starts nothing itself. |
