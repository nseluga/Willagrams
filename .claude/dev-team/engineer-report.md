**Branch:** item/audio-catalogue
**Gate:** `swift test --package-path Tests/AudioTests` — `Test run with 13 tests in 2 suites passed` (baseline 6 seam tests unchanged, +7 catalogue tests)

Files:
- ADDED — Willagrams/Audio/AudioCatalogue.swift — `AudioCue` (assetName/volume/haptic) + `AudioCatalogue.cue(for:)`, exhaustive switch, no `default:`, `import Foundation` only.
- ADDED — Tests/AudioTests/Cases/AudioCatalogueTests.swift — 7 tests, one per done-when criterion plus asset-name regex and `Equatable` value check.
- UNCHANGED — Willagrams/Audio/AudioPlayer.swift, Tests/AudioTests/Cases/AudioSeamTests.swift, Tests/AudioTests/Package.swift.

Guardrails: no `default:` arm; Foundation only (no AVFoundation/UIKit, no Style reference); AudioPlayer.swift not edited; all nine asset names match `^[a-z][a-z0-9-]*$`.

Table: tile-place .55/light · tile-recall .45/light · draw .7/medium · swap .7/medium · invalid .8/medium · countdown-tick .4/nil · win 1.0/heavy · loss .85/heavy · menu-tap .5/light.

INFO — `.claude/dev-team/analyze-report.md` absent in this worktree; item judged too small for dt-analyze, absence expected.
INFO — `Tests/AudioTests/AudioSrc` is a directory symlink to `Willagrams/Audio`, so the new file joins the test target with no `Package.swift` edit.
PROCESS — first engineer pass shipped the source file but neither the test file nor this report; both required an explicit follow-up message.
