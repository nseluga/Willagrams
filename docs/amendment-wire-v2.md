
---

## Outcome — landed

All items above are implemented on `main`. Engine: 42 tests / 7 suites (was 36).
MatchTests: 100 tests / 18 suites, unchanged from before the amendment, verified
over three serial runs. `swift build` clean.

Two things worth carrying forward:

**Pool size and letter distribution were cut.** The wire carries neither. The
pool stays at 144 with a fixed composition this round, so the "literal letter
counts, not a preset name" decision never had to be implemented. Adding them
later is a wire bump; adding a dictionary is not, because the catalogue is keyed
by id and hash.

**`MatchSession` sits at a Swift 6.3.3 toolchain limit.** Adding one more
*observed* stored property to that class makes MatchTests abort with
`swift_task_dealloc` — "freed pointer was not the last allocation" — while the
reconnect task is suspended in `peerDropped()`. Bisected to a bare
`var probe: Int = 0`; marking any one existing observed property
`@ObservationIgnored`, keeping the net count unchanged, makes it pass. It is a
layout threshold, not a defect in this amendment's logic, and it is latent on
`main` — this change merely crossed it. `options` and `optionsRefusal` are
therefore stored `@ObservationIgnored` behind computed properties that touch an
observed one, which preserves SwiftUI observation. The structural fix, if this
recurs, is to consolidate `MatchSession`'s observed state into a single observed
struct; that is a foundation item, not a lane one.
