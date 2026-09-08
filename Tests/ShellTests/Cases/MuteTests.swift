import Foundation
import Testing

import Audio

@testable import Shell

/// The mute control: what it persists, what it tells the player, and what it
/// deliberately leaves alone.
@Suite("Mute")
@MainActor
struct MuteTests {

    /// A scratch `UserDefaults` suite, unique per test. Never `.standard`:
    /// these tests write the same key the app writes.
    private static func scratchSuite(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "MuteTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        guard let suite = UserDefaults(suiteName: name) else {
            Issue.record("could not open the scratch suite \(name)")
            return
        }
        try body(suite, name)
    }

    @Test("Mute survives a rebuild, and the freshly built player comes up muted")
    func mutePersistsAcrossARebuild() {
        Self.scratchSuite { suite, _ in
            let first = ShellModel(
                services: ShellServices(
                    audio: RecordingAudioPlayer(),
                    audioSettings: AudioSettings(defaults: suite)
                )
            )
            #expect(first.isMuted == false)
            first.toggleMute()
            #expect(first.isMuted)

            // Built the way `WillagramsApp` builds it: the player's initial
            // mute comes from the persisted value, not from the model.
            let player = RecordingAudioPlayer(muted: AudioSettings(defaults: suite).isMuted)
            let rebuilt = ShellModel(
                services: ShellServices(audio: player, audioSettings: AudioSettings(defaults: suite))
            )
            #expect(rebuilt.isMuted)
            #expect(player.isMuted)
        }
    }

    @Test("Toggling mutes the player, still taps, and never touches haptics")
    func togglingMutesThePlayer() {
        Self.scratchSuite { suite, _ in
            let player = RecordingAudioPlayer()
            let shell = ShellModel(
                services: ShellServices(audio: player, audioSettings: AudioSettings(defaults: suite))
            )

            shell.toggleMute()

            #expect(player.isMuted)
            // The positive twin: the player, not the model, decides silence, so
            // the cue is still recorded while muted.
            #expect(player.effects.contains(.menuTap))
            #expect(player.impacts.isEmpty)

            shell.toggleMute()
            #expect(shell.isMuted == false)
            #expect(player.isMuted == false)
            #expect(AudioSettings(defaults: suite).isMuted == false)
        }
    }
}
