# Willagrams — shell lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** round 3 in progress — items 1–9 of 12 done, none blocked. Online host and join are live-proven on two simulators.
- **Next:** item 10 (invite a friend to play, in-app), then items 11 and 12 (sound).
- **Blockers:** none. One amendment for a later round: declining a friend request currently blocks the person, and nothing can undo it.
- **Last updated:** 2026-09-05

## Round 3 — every screen reachable, against the live backend

| Item | Status |
|------|--------|
| Build the app's services once, at the root, and inject them | done — The app now builds its backend connection, sound player and saved settings a single time when it launches and hands them to every screen, and in a development build it signs in automatically in the background so online features can switch on without ever making the menu wait. |
| Let `MatchRun` run a match it did not build | done — A running match is now handed its opponent from the outside instead of building one itself, so the same match screen can drive a practice game against the bot or a real person online, and the old opponent is always shut down before the next one starts. |
| Host a match from the menu and show the invite code | done — The menu now has a "Play a Friend" button that opens a lobby showing a six-character invite code you can share, lists who has joined, and only lets you start once a second player is there; cancelling shuts the match down and returns you to the menu. Proven on two phones during the next item. |
| Join a match by invite code | done — You can now type a friend's six-character code to join their game; the screen tells you it is waiting for them and names them, and a wrong, full or already-started code gets a plain message beside the box instead of failing silently. Proven end to end on two phones: the guest joined and both reached the game when the host pressed Start. |
| Show reconnecting, end on gone, and give online results a way home | done — When your opponent drops out the board dims, names them and stops taking taps until they are back; if they leave for good the game ends on a screen that says the opponent left rather than naming a winner, and an online game offers only Main Menu instead of a rematch that could not work. |
| Present the settings lane's options view and persist the choice | done — Solo setup now shows the real options screen instead of its own duplicate controls, and whatever you pick is remembered for next launch and used when you host a game for a friend. |
| The profile screen | done — The menu now opens your profile, showing your display name, your friend code with a Copy button, and your four match statistics exactly as the server reports them; you can rename yourself and it saves, and a name that is empty or too long is refused before anything is sent. |
| The friends list | done — The menu now opens a Friends screen listing the people you have added, the requests waiting on you and the ones you have sent, each with the person's real name; you can accept, decline or block from the list, and blocked players disappear from all three sections. Proven against the real database with two separate accounts, so the server's own permission rules are what allow each side to see the other. |
| Add a friend by code, and open a friend's profile | done — The Friends screen now has a box for a friend's code: type one and it shows you who it belongs to with a Request button, and your own code is refused before anything is sent. Tapping someone you are already friends with opens their profile with their statistics, read-only, and Back returns to the friends list rather than the menu. |
| Invite a friend to play, in-app | not started |
| Give every sound cue a call site | not started |
| The mute control | not started |
| Sign in with Apple | skipped — below stop marker |
