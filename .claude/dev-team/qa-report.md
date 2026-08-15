---
# QA Report
**Task:** Build the wire codec — `Willagrams/Match/MatchCodec.swift`
**Branch:** item/match-codec
**Date:** 2026-08-14
**Gate mode:** tests

## VERDICT: PASS

## Criteria Checked
- Each of the nine MatchMessage cases round-trips encode→decode unchanged, including all four RejectionReason values — `MatchCodecTests.everyCaseRoundTrips` (existing, engineer's) — PASS
- Every element of wire-v1.json decodes to the expected MatchMessage value — `MatchCodecTrustBoundaryTests.goldenFixtureDecodesToExpectedValues` (new: hand-built expected values from the spec literals, compared against fixture bytes decoded via `MatchCodec.decode`, never re-encoded through this build's own encoder) — PASS
- A start carrying a version other than WireFormat.current is refused with a defined error and no match state is entered — `MatchCodecTrustBoundaryTests.foreignVersionsAreRefused` (new, parametrized over 0, -1, Int.max, current+1, current+1000, driving `MatchCodec.decode` directly and asserting it throws `.unsupportedVersion` rather than returning any `MatchMessage`) — PASS
- Gate applies only to `.start`, other 8 cases carry no version and still decode — `MatchCodecTrustBoundaryTests.nonStartCasesIgnoreTheVersionGate` (new) — PASS
- Truncated and structurally invalid Data return a decode error rather than trapping — `MatchCodecTests.truncatedDataFailsToDecode`/`garbageDataFailsToDecode` (existing) plus `MatchCodecFuzzTests.truncationNeverTraps` and `.mutationNeverTraps` (new: every truncation prefix 0..full-length and 10 seeded single-byte mutations per corpus item, fixed seed 0xC0FFEE, across all 12 wire cases + all 12 golden fixture elements) plus 8 targeted edge cases (empty Data, bare `null`, `[]`, `{}`, `{"start":{}}`, wrong field type, unknown case name, 1000-deep nested JSON) — PASS

## Failures
none

## Tests Added
- `Tests/MatchTests/Cases/MatchCodecTrustBoundaryTests.swift` — exact-value golden fixture decode (gap 1), version gate driven only through `MatchCodec.decode` covering negative/zero/huge/near versions (gap 2), non-start cases bypass the gate, and a compile-time proof `MatchCodecError` is exhaustively switchable with no `default:` (gap 4)
- `Tests/MatchTests/Cases/MatchCodecFuzzTests.swift` — deterministic fuzz harness (fixed-seed LCG `SeededGenerator`, no new dependency) covering every truncation prefix and seeded single-byte mutation of a 24-item corpus (all 12 `MatchMessage` cases + all 12 raw fixture elements), plus 8 explicit malformed-input cases (gap 3)
- No new test infra: reused the engineer's existing standalone SwiftPM harness at `Tests/MatchTests/` unmodified, and reused `MatchCodecTests.{player,everyCase,goldenFixtureURL}` from the engineer's file (same test target, internal visibility) rather than duplicating fixtures

## Not Verifiable
none

---
Observed counts:
- `swift test --package-path Tests/MatchTests` → 20 tests, 3 suites, 0 failures (was 6/1/0 baseline; +14 new)
- root `swift test` (worktree root) → 36 tests, 6 suites, 0 failures (unchanged baseline, confirmed after adding new tests)

Guardrail checks run:
- `git status --porcelain` before commit: only the two new test files under `Tests/MatchTests/Cases/`; `wire-v1.json`, `MatchMessage.swift`, `project.pbxproj` untouched
- `grep -inE "bunch|split|peel|dump|banana|rotten"` over both new files: no matches
- `grep -n "^import"` over `MatchCodec.swift` + all files in `Tests/MatchTests/Cases/`: only Foundation/Testing/WillagramsRules — no GameKit/UIKit/SwiftUI
- `grep -nE '!\s|try!|fatalError|as!|\[[0-9]'` over `Willagrams/Match/MatchCodec.swift`: no matches (unchanged from engineer's version)
- Confirmed `Willagrams/Match/MatchTransport.swift` and `FakeTransport.swift` do not exist in the worktree
