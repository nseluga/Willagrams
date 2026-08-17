# Settings lane — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** running — autonomous session, 4 of 5 items resolved
- **Next:** The rules-in-force summary
- **Blockers:** none
- **Last updated:** 2026-08-17

## Round 1 — settings lane

| Item | Status |
|------|--------|
| Settings test package and the ruleset type | done — Settings code now has its own test suite, and there is a named "Standard" ruleset holding the default match rules. |
| Dictionary catalogue | done — The game can look up a word list by name and knows its exact contents, so both players are guaranteed to be playing off the same dictionary. |
| Settings persistence | done — The rules a host picks are saved between launches, and fall back to the standard rules if the saved data is missing or damaged. |
| Host's options form | done — The host now has a screen to turn Swap off, set a minimum word length, and pick the word list, with out-of-range values corrected automatically. |
| Rules-in-force summary | not started |
