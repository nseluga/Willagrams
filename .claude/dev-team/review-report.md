# Review Report
**Branch:** item/match-codec
**Date:** 2026-08-14
**Files Reviewed:** 1 production (Willagrams/Match/MatchCodec.swift); MatchMessage.swift, Package.swift/MatchSrc, MatchCodecTests.swift read for context only
**Dimensions Swept:** Efficiency (1 minor, confirmed non-issue), Reliability (clean — no traps, both error paths return), Scalability (clean, fixed 2-player wire size), Safety & Security (3 important — see below), Fault Tolerance (clean/N/A — decode is a stateless pure function, no retry semantics owned here), Data Integrity (clean/N/A — no identity/dedupe keys minted here), Over-Engineering (clean — hand-written `==` is necessary, `any Error` isn't Equatable)

**Guardrails checked:** wire-v1.json and MatchMessage.swift untouched (`git diff lane/match..HEAD --stat` confirms). No compat/migration shim for foreign versions. No GameKit/UIKit/SwiftUI import in MatchCodec.swift. Two-player only, no N-generalization. No banned terms (bunch/split/peel/dump/bananas/rotten) in MatchCodec.swift or the test file (grepped). MatchTransport.swift/FakeTransport.swift not touched. `.gitignore`, `Tests/MatchTests/Package.swift`, `Tests/MatchTests/MatchSrc` changed outside the lane's two owned paths — but by the prior commit `74f0c24` (harness wiring), not the codec commit `50e44f6` — flagged Minor below, not gating.

No Critical findings.

## Important
Important — Willagrams/Match/MatchCodec.swift:8-28 — `MatchCodecError` isn't `Sendable` (`underlying: any Error` blocks synthesis), and this error will need to cross from `GKMatchTransport`'s async-stream callbacks into the observable `MatchSession`; Swift 6 strict concurrency will reject that crossing once it happens. Fix: constrain to `underlying: any Error & Sendable` and declare `MatchCodecError: Error, Equatable, Sendable`. Confirms engineer's self-flag — real, not hypothetical.
Important — Willagrams/Match/MatchCodec.swift:41-54 — the version gate fires only for callers who go through `decode(_:)`; nothing stops a downstream caller from calling `JSONDecoder().decode(MatchMessage.self, from:)` directly on peer bytes and getting an un-refused foreign-version `.start`. This exact call shape already exists in the repo (Tests/WillagramsRulesTests/MatchMessageTests.swift:38), so it's not a theoretical path. MatchCodec can't close this itself — `MatchMessage`'s public Codable conformance lives in the guarded MatchMessage.swift, out of this lane's reach. Smallest fix in scope: make it a hard rule that `GKMatchTransport.swift` is the only place peer bytes are read and it must call `MatchCodec.decode` exclusively (review that item for it); moving the gate into `MatchMessage.init(from:)` is a larger, separate change to the guarded contract file.
Important — Willagrams/Match/MatchCodec.swift:44 — no size/depth cap before handing `data` to `JSONDecoder().decode`. A message within GameKit's ~16KB reliable-send ceiling can still carry thousands of levels of array nesting, risking parser stack exhaustion before MatchMessage's flat shape is even type-checked. This belongs in GKMatchTransport.swift, not here: that file owns the actual untrusted network read and already inherits GameKit's size ceiling, so a cheap reject-oversized check before calling `MatchCodec.decode` is the right trust boundary. MatchCodec transforms already-local, already-bounded `Data` — it shouldn't duplicate that check.

## Minor
Minor — Willagrams/Match/MatchCodec.swift:38,44 — fresh `JSONDecoder`/`JSONEncoder` per call, confirmed. At 2-player turn-based message volume this is not a measurable cost — no action needed, downgrading engineer's flag to non-issue.
Minor — .gitignore / Tests/MatchTests/Package.swift / Tests/MatchTests/MatchSrc — touched outside `Willagrams/Match/**` and `Tests/MatchTests/**` ownership, but by the prior harness-wiring commit, not this item's commit; necessary SwiftPM scaffolding (root Package.swift is protected), not a defect.

## Doc-comment claim
MatchCodec.swift:32-35 claims a caller "who goes through it can never come away with a `.start` carrying a version this build doesn't know." Verified TRUE as scoped: `decode(_:)` matches `.start` after JSONDecoder succeeds and throws before returning on any mismatch, no other exit path inside the function. The claim is correctly scoped to callers of `decode(_:)` — see the Important bypass finding above for the gap that scoping leaves.

## Error taxonomy
Exhaustive (2 cases), and nothing in this diff switches over it with a `default:` — clean, no silent-swallow risk today.

## STANDARDS.md Updates
Skipped — this is a read-only worktree review per task instructions (no file edits beyond this report).
