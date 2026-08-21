# The design comp, and what this repo built from it

**Source:** Claude Design project `fa88a423-7183-4d9c-85a3-eee18530827b`, file
`Willagrams Screens.dc.html`. The comp is copied in here as
`willagrams-screens.dc.html` so it outlives the session that fetched it.

**Standing rule, set by Nate when the comp arrived:** the repo is the truth for
functionality; the comp is the truth for visual design, aesthetics and layout,
and nothing else. Where the two disagree about what the app *does*, the repo
wins and the disagreement is written down here rather than resolved in code.

The visual pass of 2026-08-20 is recorded in `MAP.md` under "Recorded crossing —
the design-comp visual pass". It changed no functionality: all 653 tests across
the seven packages are unchanged, which is the evidence.

## Screen by screen

| # | Comp screen | Repo file | State |
|---|---|---|---|
| 01 | Launch | — | **Not built.** See "Launch screen" below. |
| 02 | Menu | `Willagrams/Shell/MenuView.swift` | Built, restyled. |
| 03 | Host / Join | — | Not built — no lane has shipped a transport. `online`. |
| 04 | Match options | `Willagrams/Settings/Views/MatchOptionsView.swift` | Built, restyled, with two deliberate departures. |
| 05 | Rules in force | `Willagrams/Settings/Views/RulesInForceView.swift` | Built, restyled. |
| 06 | Countdown | `Willagrams/Shell/CountdownView.swift` | Built, restyled. |
| 07 | Results | `Willagrams/Shell/ResultsView.swift` | Built, restyled, minus the stat table. |
| 08 | In-match HUD | `Willagrams/Shell/MatchHUD.swift` | Built. Untouched by this pass — see below. |
| 09 | How to play | `Willagrams/Shell/HowToPlayView.swift` | Built, restyled, minus the pager. |
| 10 | Connection lost | — | Not built. The data exists; the screen does not. |
| 11 | Account / Friends | — | Not built. `account` and `friends` lanes. |

## What the comp shows that this repo deliberately does not build

Each of these is a *functional* addition wearing visual clothes. The visual pass
was explicitly scoped to layout, type, colour, spacing, card treatment and the
wordmark, so each was left for the lane that owns the behaviour.

### Pool size and letter distribution pickers (screens 04, 05, 06)

The comp offers 96 / 144 / 180 and a distribution control. `MAP.md` records the
opposite decision: "Pool size and letter distribution were cut — the pool stays
at 144 with a fixed composition." The repo is right and the comp is out of date.
If a pool readout is ever wanted on screen it is a readout, not a picker.

### The three-up minimum-word-length control (screen 04)

The comp shows a segmented 2 / 3 / 4. `MatchOptions.lengthRange` is `2...15` and
`MatchOptionsForm.minimumWordLength` clamps to it, so a three-up control would
silently delete 5 through 15 from the product. The `Stepper` stays. A segmented
control becomes correct only if the *rule* narrows first, in
`Sources/WillagramsRules/MatchOptions.swift`, which is protected.

### The results stat table (screen 07)

The comp wants draws called, swaps made, and a fastest time. `MatchSession`
counts none of them. Adding counters is a `match` lane item with a wire question
attached — the opponent's numbers have to arrive from somewhere.

### The "1 OF 2" rules pager (screen 09)

There are five rules and the comp pages them four at a time. Paging needs state
and two controls on a screen whose only control is Back. The grid scrolls
instead. A pager is a fine round-2 item; it was not a visual change.

### The player handle, the opponent name, and the avatar (screens 02, 03, 07, 11)

`@nate`, "Jordan M." and the avatar chips are all `account` and `friends` lane
data. `Willagrams/Online/BackendContracts.swift` already defines `Profile` with
`displayName` and `friendCode`, and `FakeBackend` serves it end to end — so
these screens are buildable now, by the lane that owns them.

### Launch screen (screen 01)

The target sets `INFOPLIST_KEY_UILaunchScreen_Generation = YES`. Replacing the
generated launch screen with the comp's means editing
`Willagrams.xcodeproj/**`, which `MAP.md` lists as unowned and Reviewer-only,
and a SwiftUI first-frame view would live in `Willagrams/App/**`, which is the
`shell` lane's. Neither is a style-lane change, so neither happened here.

### The in-match HUD (screen 08)

Left alone on purpose. The HUD sits over a live board and reads
`MatchHUDModel`; restyling it means judging it against motion and drag states
this pass cannot exercise. The comp's HUD is also the screen it takes the most
liberty with. This is the one screen where a lane should re-read the comp rather
than trust a translation of it.

## The primitives the pass added

Four things the comp repeats across eleven screens, now in `Willagrams/Style/`
and inside `StyleSourceTests.views` so the guardrails police them:

  - **`BrandLabel`** — `.monoLabel()` and `.monoLabelAccent()`. The tracked-out
    Fragment Mono metadata line. It does not uppercase: callers pass the string
    they mean, so a `Terminology` word stays that word and only its *case* is
    the label's, via `.textCase(.uppercase)` at the call site.
  - **`WordmarkTiles`** — the mark as a crossword. WILLA across, GRAMS down, the
    shared `A` inverted into the accent. Deliberately not `BrandTile`: a rack
    tile carries placement state and a liftable bevel, and a printed mark can be
    in neither.
  - **`ScreenHeader`** — back, title, and an optional mono count on the right.
    Takes a closure and a back title, because `Style` knows nothing about
    routing and the app's words live in the shell.
  - **`StatRow`** — one label-value line with an opt-in rule under it.

## If you are the next lane

Read `MAP.md` first — the crossing entry and the "Open — the Release fence"
entry. Then this file, for the screen you are about to build. The comp is a
picture of an app that is further along than this repo; treat every element on
it as a claim to check against `MAP.md` before you implement it.
