# Engineer Report
**Task:** Build the wire codec — `Willagrams/Match/MatchCodec.swift`
**Branch:** item/match-codec
**Date:** 2026-08-14

## Design Decisions
- `MatchCodecError` is a small `Error, Equatable` enum with two cases: `unsupportedVersion(received:expected:)` and `malformedPayload(underlying: any Error)` — exhaustive taxonomy callers can switch on, underlying `DecodingError` kept but not required.
- `MatchCodec.decode(_:)` uses Swift 6 typed throws (`throws(MatchCodecError)`) — the only entry point, and the compiler enforces it can never return a `.start` at a foreign version: the version check runs inside `decode` itself before returning, so a mismatch throws instead of yielding a value.
- `encode(_:)` stays a plain `throws -> Data` (untyped) since it operates on locally-constructed, trusted values, not peer input — not part of the trust boundary the task calls out.
- Equatable on `MatchCodecError` treats all `.malformedPayload` instances as equal (underlying `any Error` isn't Equatable); `.unsupportedVersion` compares its two Ints. Sufficient for callers asserting "which case," not "which exact decode failure."

## Files Changed
- `Willagrams/Match/MatchCodec.swift` — new. `MatchCodecError` + `MatchCodec.encode`/`decode`. No GameKit/UIKit/SwiftUI imports; compiles standalone on macOS.
- `Tests/MatchTests/Cases/MatchCodecTests.swift` — new. 6 tests: all-cases round-trip via codec, golden fixture decodes through codec, foreign version refused with exact error, current version accepted, truncated data and garbage bytes both fail via `.malformedPayload` without trapping.

## Deferred / Out of Scope
- Nothing deferred. MatchMessage and wire-v1.json untouched per guardrails; no new case found missing.

## Flags for Reviewer
- `decode` allocates a fresh `JSONDecoder`/`JSONEncoder` per call — fine at 2-player message volume, would want a shared instance if this becomes a hot path.
- `malformedPayload`'s underlying error is stored as `any Error`, not `Sendable`-constrained — fine for local catch/log use, would need tightening if `MatchCodecError` ever crosses an actor boundary.
