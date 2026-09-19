# App Store listing — Willagrams 1.0

Every field App Store Connect asks for, with the value to paste. Character
counts are Apple's limits, checked against the text below.

## App Information

| Field | Value |
|---|---|
| Name (30) | `Willagrams` |
| Subtitle (30) | `Race to build your word grid` |
| Primary category | Games |
| Secondary category | Word *(under Games; optional but it is the one people browse)* |
| Bundle ID | `com.willagrams.Willagrams` — already correct |
| SKU | `willagrams-ios-2026` — already correct |
| Content rights | Does not contain, show, or access third-party content |
| Age rating | Expect **4+** — every questionnaire answer is None/No. See below. |

> **The Name field currently reads `Nate Seluga`.** That is the store listing
> name, not the developer name, and it has to be changed before submission.

### Age rating questionnaire — the answers

All of In-App Controls, Capabilities, Mature Themes, Medical or Wellness,
Sexuality or Nudity, Violence and Chance-Based Activities are **None / No**,
with one judgement call:

- **User-Generated Content** — a player picks a display name that other players
  see. There is no chat, no messaging and no free-text field beyond that name.
  Apple's threshold is content *sharing* between users; a display name alone has
  not historically tripped it. Answer **No**, and if a reviewer disagrees the
  remedy is a rating bump, not a rejection.

## Version 1.0 page

### Promotional Text (170)

```
Build your grid, empty the bag, and finish before your friend does. Online play
is here — invite someone with a code and race them in real time, on iPhone or
iPad.
```

### Description (4,000)

```
Willagrams is a word race. Draw a hand of letter tiles, build them into a
crossword grid of your own, and empty your hand before your opponent empties
theirs.

There is no turn to wait for. Both players build at the same time, out of the
same shrinking bag of tiles. Whenever someone runs out of letters, everybody
draws — so falling behind hands you more tiles to place, and pulling ahead puts
the squeeze on the other side. Once the bag is empty, the first player whose
grid is complete and every word valid takes the win.

PLAY A FRIEND
Invite someone and play in real time. Add people with an eight-character friend
code and your friends list is waiting next time. Matches survive a bad
connection: if either player drops, both boards pause, and when they return both
sides resume together on a shared countdown.

SOLO PRACTICE
Play the computer at Easy, Medium or Hard. The bot places its tiles at a human
pace, so you watch a board get built instead of watching a finished one appear.

BUILT FOR TOUCH
Drag a tile to move it. Double-tap a letter to select it, then sweep across to
grab a whole run and move it as one piece. Words that do not work flash instead
of blocking you, so you can pull your grid apart and put it back together
whenever you like.

NO ACCOUNT, NO ADS
No sign-up, no email, no password — online play makes you an anonymous profile
on the spot. No advertising, no analytics, no tracking of any kind.

Universal for iPhone and iPad.
```

### Keywords (100)

```
word,anagram,crossword,tiles,puzzle,letters,spelling,friends,multiplayer,vocabulary,brain,solo
```

94 characters. No app name and no category words — Apple already indexes those,
so spending characters on them is waste.

### URLs

| Field | Value |
|---|---|
| Support URL | `https://nseluga.github.io/Willagrams/` |
| Marketing URL | *(leave empty — optional)* |
| Privacy Policy URL | `https://nseluga.github.io/Willagrams/privacy.html` |

Both are served from the `gh-pages` branch of this repo.

### Copyright (200)

```
2026 Nathaniel Seluga
```

### Version Release

**Manually release this version.** A first submission is worth releasing on
purpose, once you have seen it approved, rather than having it appear while you
are not looking.

## App Review Information

**Sign-in required: leave unchecked.** There is no login screen. Online play
creates an anonymous session by itself and asks the player for nothing.

### Notes (4,000)

```
Willagrams is a word game. No account, login, or payment is needed — tapping
Play a Friend creates an anonymous profile automatically.

TESTING ONLINE PLAY WITH ONE DEVICE
"Play a Friend" is real-time and needs two devices, so a single reviewer cannot
complete an online match alone. Solo Practice exercises the identical board,
rules and match flow against a computer opponent, and is the fastest way to see
the whole game. Please use it if a second device is not available.

TESTING ONLINE PLAY WITH TWO DEVICES
1. On both devices open Play a Friend.
2. Device A: Host, then share the invite with device B.
3. Device B: Join, and enter the invite.
4. The match starts for both. Tiles can be dragged and the grid rebuilt freely.

HOW THE GAME IS WON
Both players build at once from one shared pool. Draw is enabled once your grid
is complete and valid. When the pool empties, the Win button enables for the
first player holding a complete, valid grid.

NOTE ON THE MENU
"Multiplayer" on the home screen is intentionally disabled and captioned
"Coming soon". It is a placeholder for a later version and is not reachable.

There is no user-to-user messaging or chat anywhere in the app. The only text a
player enters is their own display name.
```

## App Privacy

Privacy Policy URL above, then the questionnaire. Willagrams contains **no
analytics and no advertising software** — the only network dependency is
Supabase, which hosts the database and the real-time match connection.

**Data collected and linked to the user** — all for **App Functionality** only,
and **none used for tracking**:

| Apple category | What it is |
|---|---|
| Identifiers → User ID | The anonymous account id and the eight-character friend code |
| User Content → Other User Content | The display name the player chooses |
| Usage Data → Product Interaction | Matches played, matches won, tiles placed, fastest win |

Everything else — contact info, health, financial, location, contacts, browsing
history, search history, photos, audio, diagnostics, purchases, sensitive info —
is **not collected**.

Answer **No** to "used for tracking" throughout. Nothing is joined with
third-party data, nothing goes to a data broker, and there is no advertising.
Because nothing is used for tracking, no App Tracking Transparency prompt is
required.

## Pricing and Availability

| Field | Value |
|---|---|
| Price | Free |
| Availability | All countries and regions |
| Distribution | Public |
| Apple Silicon Macs | Leave off — the board is tuned for touch, and a Mac build is untested |
| Apple Vision Pro | Leave off — same reason |

Free means no Paid Applications agreement is needed.

## Still required, and only you can do them

- **Digital Services Act trader information**, under App Information. Unset, and
  it blocks EU availability. Needs your legal identity and address.
- **Screenshots.** iPhone 6.5" at 1242 × 2688 or 1284 × 2778, plus an iPad set,
  since the app ships universal. iPhone supports portrait and landscape; iPad is
  landscape only, so its screenshots must be landscape.
- **The upload itself**, which needs an App Store Connect API key or an
  app-specific password.
