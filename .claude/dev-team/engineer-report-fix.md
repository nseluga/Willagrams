# Fix Report
**Branch:** `lane/audio` — commit `50a2faf`
**Date:** 2026-08-25
**Findings addressed:** 4 of 4 Important (0 disputed, 0 deferred; Minor + Over-Engineering left alone as instructed)

## Changes Made
- `SystemAudioPlayer.swift:140-148` — `activateSessionIfNeeded` now `guard (try? setCategory(.ambient…)) != nil else { return }` before `sessionReady = true`, so a refused category retries on the next cue instead of latching `.soloAmbient` — review Important (Fault Tolerance)
- `SystemAudioPlayer.swift:95-99,125-131` — `play` stamps `DispatchTime.now()`; `emit` drops a cue older than 200ms, so a request deferred behind a cold preload never fires seconds after its own haptic — review Important (Reliability)
- `SystemAudioPlayer.swift:150-158` — added `#if DEBUG public func debugVoices<T>(_:_:)` doing `queue.sync { body(voices[effect] ?? []) }`; behaviour unchanged, no assertion weakened — review Important (Reliability, findings 3+4)
- `SimulatorSmoke/main.swift:41-56,105-136` — `Mirror` reflection deleted; harness samples `id`/`isPlaying`/`currentTime`/`volume` into a `VoiceState` *inside* `debugVoices`, so neither the `voices` dictionary nor any `AVAudioPlayer` is touched off `queue` — review Important (Reliability, findings 3+4)
- `SimulatorSmoke/run.sh:11` — `-D DEBUG` added so the accessor compiles into the smoke binary

## Notes
- `queue.sync` makes the preload poll loop block until preload finishes, so the C3/C6 plays land on an idle queue and never hit the 200ms staleness window — C6 passes unmodified, no window widening and no added wait needed (`ok: 3 voices preloaded after 0.0s`).

## Verification
- `swift test --package-path Tests/AudioTests` → `Test run with 17 tests in 3 suites passed after 0.009 seconds.`
- `xcodebuild … -destination 'platform=iOS Simulator,name=iPhone 17' build` → `** BUILD SUCCEEDED **`
- `./Tests/AudioTests/SimulatorSmoke/run.sh` → `ok C1/C4` / `ok C2/C3` / `ok C3` / `ok C6: overlapping plays use two distinct voices` / `ok C1` / `ALL OK`
