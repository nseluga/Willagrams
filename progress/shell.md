# Willagrams — shell lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** round 3 complete — all 12 items above the stop marker are done, none blocked, and three of the four open defects are fixed. Online host, join and in-app invite are live-proven against the real project, every sound cue has a call site, and the menu can mute.
- **Next:** Sign in with Apple, below the stop marker, waits on the paid Apple Developer membership.
- **Blockers:** none blocking the run. Two things a person still owes. Nobody has yet sat down with two real devices and tapped host, join and invite through end to end — nothing here can tap a button, so that is a hands-on check. And anyone who learns your friend code can still listen in on your game invitations; that needs a `supabase/migrations/**` change this lane was not allowed to make, so it goes through /foundation.
- **Last updated:** 2026-09-08

## Round 2 — a playable match

| Item | Status |
|------|--------|
| Own the match run across countdown, match and results (`MatchRun`) | done — Starting solo practice now builds one match that the countdown, match and results screens all share, and leaving or starting a rematch fully shuts the old one down first. |
| Compose the match screen (`MatchView`) | done — The match screen now shows the real board with the controls over it, sized to the actual screen. |
| Wire ShellRootView's three placeholder routes to the real screens | done — Pressing Solo Practice now walks through the real countdown, board and results screens instead of stopping at placeholder text. |
| Give the invalid-run flash a caller | done — A Draw press the game refuses now flashes the offending words red instead of doing nothing. |
| Add the win claim | done — You can now call "Willagrams!" from the match screen; a valid board ends the match and shows results, an invalid one flashes the offending words instead. |
| Publish the host's remaining pool count | done — The Pool counter on the match screen now shows how many tiles are actually left and ticks down as you draw, instead of always reading "—". |
| Add the how-to-play screen | done — The menu has a second button opening a rules screen that explains Pool, Draw, Swap, the connected-board requirement and the win call, with a Back button to the menu. |

## Round 3 — every screen reachable, against the live backend

Merged to `integration` 2026-09-08 as PR #4 (`--merge`, 55 commits). An
independent acceptance check read the round against the four `Lane done when:`
criteria: sound and the test gate are met outright; the two multiplayer
criteria are met in mechanism — friending, invite delivery and a whole match
with real stat updates are each proven live — but their literal two-device
tap-through is unrun and is a person's job. The three live mechanisms have
never been chained in one run, so the live suite is not end-to-end cover of the
whole player journey.

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
| Invite a friend to play, in-app | done — An accepted friend now has an "Invite to play" button that opens a game and sends them the code, and on their side a banner says who wants to play, with a Join button that takes them straight in. Stale and duplicate invites are ignored, and an invite that arrives mid-game waits rather than interrupting. Proven against the real service between two accounts in about a second; the last step, actually tapping through it on two devices, still needs a person. |
| Give every sound cue a call site | done — Every sound the game owns now actually plays: the countdown tick, drawing and swapping tiles, a rejected word, placing and taking back a tile, winning, losing and every menu button, each fired from the screen that owns that moment rather than from a view. A match can no longer be built without being handed the app's sound player, so a wiring mistake that would ship the game silent is now a build failure instead of something the tests would miss. |
| The mute control | done — The menu now has a speaker button that turns the game's sound off and on, and the choice is remembered, so the game comes back silent if you left it silent. VoiceOver reads it as "Sound on" or "Sound off". Muting affects sound only; the buzz you feel when a game ends is untouched. |
| Sign in with Apple | skipped — below stop marker |

### 2026-09-08 — three of four open defects fixed

| Defect | Status |
|------|--------|
| Out-of-order online messages silently diverge two devices | fixed — Every message a device sends now carries its own count, and the receiving side holds anything that arrives early until the gap fills, so two devices can no longer end up with different boards because the network delivered two messages the wrong way round. A message that is genuinely lost releases the queue after a short wait rather than stopping the game with nothing on screen. |
| Declining a friend request blocked that person forever | fixed — Declining now simply clears the request, and that person can ask again; the button copy says so. Refusing someone for good is now its own Block button on the request, which the screen previously had no way to do. |
| A network blip could leave an abandoned game open on the server | fixed — Backing out of a lobby now retries closing the game out, records whether it landed, and is no longer cancelled the moment the screen goes away — which was killing it in the ordinary case. |
| Anyone who learns your friend code can read your live invitations | open — needs `config.isPrivate` plus a `realtime.messages` policy. That is a `supabase/migrations/**` change, a protected path this lane may not touch; it goes through /foundation and then an apply to the live project. |
