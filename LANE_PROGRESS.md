# Settings lane — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** complete — all 5 items done, none blocked. 453 tests pass across
  all five packages, 0 failures.
- **Next:** `/merge-lane` — the lane branch is pushed and a PR into `integration`
  is open. Nothing in this lane is wired into a screen yet; the shell lane owns
  navigation into the options and rules-in-force views.
- **Blockers:** none
- **Last updated:** 2026-08-17

## Round 1 — settings lane

| Item | Status |
|------|--------|
| Settings test package and the ruleset type | done — Settings code now has its own test suite, and there is a named "Standard" ruleset holding the default match rules. |
| Dictionary catalogue | done — The game can look up a word list by name and knows its exact contents, so both players are guaranteed to be playing off the same dictionary. |
| Settings persistence | done — The rules a host picks are saved between launches, and fall back to the standard rules if the saved data is missing or damaged. |
| Host's options form | done — The host now has a screen to turn Swap off, set a minimum word length, and pick the word list, with out-of-range values corrected automatically. |
| Rules-in-force summary | done — Both players can see a short list of the rules the host chose, showing only what differs from standard plus the word list in use. |
