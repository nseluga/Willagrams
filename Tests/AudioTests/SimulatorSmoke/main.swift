import Foundation

// A bundle with no audio assets in it — the shipping state until the sound
// files land. `run.sh` points this at an empty directory.
let path = ProcessInfo.processInfo.environment["SMOKE_EMPTY_BUNDLE"] ?? "/nonexistent"
let player = SystemAudioPlayer(bundle: Bundle(path: path) ?? Bundle.main)

assert(player.isMuted == false, "fresh player is unmuted")
player.setMuted(true)
assert(player.isMuted == true, "setMuted(true) round-trips")
player.setMuted(false)
assert(player.isMuted == false, "setMuted(false) round-trips")

// Unmuted, no assets: every cue is a silent no-op rather than a crash.
for effect in SoundEffect.allCases { player.play(effect) }

// Muted: still no crash, still no sound.
player.setMuted(true)
for effect in SoundEffect.allCases { player.play(effect) }

// Haptics fire regardless of mute.
player.impact(.light)
player.impact(.medium)
player.impact(.heavy)

// Let the private audio queue drain before exiting.
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
print("OK: mute round-trips; empty-bundle play and impact are safe no-ops")
