# Willagrams — shell lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** round 3 in progress — item 1 of 12 done, none blocked. Run paused after item 1 at the user's request.
- **Next:** item 2 — let `MatchRun` run a match it did not build (the `MatchOpponent` seam).
- **Blockers:** none.
- **Last updated:** 2026-09-04

## Round 3 — every screen reachable, against the live backend

| Item | Status |
|------|--------|
| Build the app's services once, at the root, and inject them | done — The app now builds its backend connection, sound player and saved settings a single time when it launches and hands them to every screen, and in a development build it signs in automatically in the background so online features can switch on without ever making the menu wait. |
| Let `MatchRun` run a match it did not build | not started |
| Host a match from the menu and show the invite code | not started |
| Join a match by invite code | not started |
| Show reconnecting, end on gone, and give online results a way home | not started |
| Present the settings lane's options view and persist the choice | not started |
| The profile screen | not started |
| The friends list | not started |
| Add a friend by code, and open a friend's profile | not started |
| Invite a friend to play, in-app | not started |
| Give every sound cue a call site | not started |
| The mute control | not started |
| Sign in with Apple | skipped — below stop marker |
