import AVFoundation
import Foundation

// Simulator smoke check for `SystemAudioPlayer`. The macOS gate cannot reach
// the type (it is behind `#if canImport(UIKit)`), so this is the only place
// the real player is executed.
//
// Two bundles are used on purpose:
//   * an EMPTY one   — every play must be a silent no-op, no crash.
//   * a LOADED one   — a generated WAV under the catalogue's asset name, so
//                      session activation and voice overlap actually happen.

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

/// One second of 44.1kHz mono silence-shaped PCM, written as a real WAV.
func writeWAV(to url: URL, seconds: Int = 2) {
    let rate = 44_100, frames = rate * seconds, bytes = frames * 2
    var d = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + bytes))
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
    le32(UInt32(rate)); le32(UInt32(rate * 2)); le16(2); le16(16)
    d.append(contentsOf: Array("data".utf8)); le32(UInt32(bytes))
    // A quiet tone, not digital silence — some decoders elide all-zero data.
    for i in 0..<frames {
        let s = Int16(3000 * sin(Double(i) * 2 * Double.pi * 440 / Double(rate)))
        withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) }
    }
    try! d.write(to: url)
}

/// Reaches the player's private, queue-confined `voices` pool. Reading real
/// object state is the only way to tell "two voices overlapped" apart from
/// "one voice restarted" from outside the type.
func voices(of player: SystemAudioPlayer, _ effect: SoundEffect) -> [AVAudioPlayer] {
    for child in Mirror(reflecting: player).children where child.label == "voices" {
        guard let map = child.value as? [SoundEffect: [AVAudioPlayer]] else {
            fail("`voices` changed shape; smoke check needs updating")
        }
        return map[effect] ?? []
    }
    fail("no `voices` property on SystemAudioPlayer")
}

func settle(_ seconds: TimeInterval = 0.4) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

let session = AVAudioSession.sharedInstance()
let defaultCategory = session.category
check(defaultCategory != .ambient, "precondition: process default category is not already .ambient")

// ---------------------------------------------------------------- empty bundle
let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("empty.bundle")
try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
let empty = SystemAudioPlayer(bundle: Bundle(path: emptyDir.path)!)

check(empty.isMuted == false, "C1: fresh player is unmuted")
empty.setMuted(true)
check(empty.isMuted == true, "C1: setMuted(true) round-trips")
empty.setMuted(false)
check(empty.isMuted == false, "C1: setMuted(false) round-trips")

for effect in SoundEffect.allCases { empty.play(effect) }
empty.setMuted(true)
for effect in SoundEffect.allCases { empty.play(effect) }
empty.impact(.light); empty.impact(.medium); empty.impact(.heavy)
settle()
check(voices(of: empty, .tilePlace).isEmpty, "C4: no assets means no preloaded voices")
check(session.category == defaultCategory,
      "C3/C4: an asset-less play must not configure the session (was \(session.category.rawValue))")
print("ok C1/C4: mute round-trips; empty bundle plays and impacts are no-ops, session untouched")

// --------------------------------------------------------------- loaded bundle
let loadedDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("loaded.bundle")
try? FileManager.default.createDirectory(at: loadedDir, withIntermediateDirectories: true)
let cue = AudioCatalogue.cue(for: .tilePlace)
writeWAV(to: loadedDir.appendingPathComponent("\(cue.assetName).wav"))
let bundle = Bundle(path: loadedDir.path)!
guard let assetURL = bundle.url(forResource: cue.assetName, withExtension: "wav") else {
    fail("precondition: the generated asset is visible to the bundle")
}
do { _ = try AVAudioPlayer(contentsOf: assetURL) }
catch { fail("precondition: AVAudioPlayer cannot decode the generated asset: \(error)") }

// --- C2: muted play makes no sound, and the session stays untouched.
let player = SystemAudioPlayer(bundle: bundle, muted: true)
settle()
// Preload is dispatched off `init`, and a cold decode on a simulator can take
// well over a second. Poll rather than guess a sleep.
var waited = 0.0
while voices(of: player, .tilePlace).count < 3 && waited < 15 {
    settle(0.25); waited += 0.25
}
print("ok: \(voices(of: player, .tilePlace).count) voices preloaded after \(waited)s")
let pool = voices(of: player, .tilePlace)
check(pool.count == 3, "C6: three voices preloaded per asset, got \(pool.count)")
check(player.isMuted, "C2: player starts muted")
player.play(.tilePlace)
player.impact(.medium)
settle()
check(pool.allSatisfy { !$0.isPlaying }, "C2: a muted play must not start any voice")
check(session.category == defaultCategory,
      "C3: session must still be unconfigured before the first audible play (was \(session.category.rawValue))")
print("ok C2/C3: muted play is silent, impact still runs, session not activated yet")

// --- C3: the first audible play configures .ambient.
player.setMuted(false)
player.play(.tilePlace)
settle(0.3)
check(session.category == .ambient,
      "C3: category must be .ambient after the first sound, got \(session.category.rawValue)")
let first = pool.filter { $0.isPlaying }
check(first.count == 1, "C6: one play starts exactly one voice, got \(first.count)")
check(first[0].volume == cue.volume, "cue volume applied, got \(first[0].volume)")
print("ok C3: first sound set category .ambient")

// --- C6: a second, immediate play overlaps on a distinct voice.
player.play(.tilePlace)
settle(0.3)
let playing = pool.filter { $0.isPlaying }
check(playing.count == 2, "C6: two quick plays must occupy two voices, got \(playing.count)")
check(ObjectIdentifier(playing[0]) != ObjectIdentifier(playing[1]), "C6: the two voices are distinct objects")
check(playing.contains { ObjectIdentifier($0) == ObjectIdentifier(first[0]) },
      "C6: the first voice kept playing rather than being restarted")
check(playing.map(\.currentTime).max()! > playing.map(\.currentTime).min()!,
      "C6: the two voices are at different playback positions, so neither was restarted")
print("ok C6: overlapping plays use two distinct voices")

// --- C1: the conformance is usable through the protocol with no `await`,
// no `try`. This block failing to compile IS the assertion.
let seam: AudioPlayer = player
seam.setMuted(true)
check(seam.isMuted, "C1: setMuted round-trips through the AudioPlayer existential")
seam.play(.menuTap)
seam.impact(.light)
seam.setMuted(false)
check(!seam.isMuted, "C1: setMuted(false) round-trips through the existential")
print("ok C1: AudioPlayer witness is non-async, non-throwing")

print("ALL OK")
exit(0)
