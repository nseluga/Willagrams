import Foundation
import Testing
@testable import Audio

// Each test gets its own scratch suite and tears it down, so nothing here ever
// touches the developer's real preferences.

@Suite("Audio settings")
struct AudioSettingsTests {

    /// Runs `body` against a fresh, empty suite and removes it afterwards.
    private func withScratchSuite(
        _ name: String = #function,
        _ body: (UserDefaults, String) throws -> Void
    ) rethrows {
        let suiteName = "AudioSettingsTests.\(name).\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not open scratch suite \(suiteName)")
            return
        }
        try body(suite, suiteName)
    }

    @Test("A fresh install is unmuted")
    func defaultsToUnmuted() {
        withScratchSuite { suite, _ in
            #expect(AudioSettings(defaults: suite).isMuted == false)
        }
    }

    @Test("The mute survives the object that set it")
    func persistsAcrossInstances() {
        withScratchSuite { suite, _ in
            AudioSettings(defaults: suite).setMuted(true)
            // A NEW instance over the same suite: this is what persistence means.
            #expect(AudioSettings(defaults: suite).isMuted == true)

            AudioSettings(defaults: suite).setMuted(false)
            #expect(AudioSettings(defaults: suite).isMuted == false)
        }
    }

    @Test("Only the one key is written")
    func writesOneKey() {
        withScratchSuite { suite, suiteName in
            AudioSettings(defaults: suite).setMuted(true)
            let written = suite.persistentDomain(forName: suiteName) ?? [:]
            #expect(Array(written.keys) == [AudioSettings.mutedKey])
        }
    }

    @Test("Constructing and using it leaves the real defaults untouched")
    func neverTouchesStandardDefaults() {
        let standard = UserDefaults.standard
        let before = standard.object(forKey: AudioSettings.mutedKey)
        #expect(before == nil, "the host's real defaults already hold audio.muted")

        withScratchSuite { suite, _ in
            let settings = AudioSettings(defaults: suite)
            settings.setMuted(true)
            #expect(settings.isMuted == true)
        }

        #expect(standard.object(forKey: AudioSettings.mutedKey) == nil)
    }
}
