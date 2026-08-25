import Foundation
import Testing
@testable import Audio

// The catalogue is the only file that decides what a moment sounds like, so
// these tests pin the table itself, not the player.

@Suite("Audio catalogue")
struct AudioCatalogueTests {

    @Test("Every moment gets its own asset — nine cases, nine distinct names")
    func assetNamesAreDistinct() {
        let names = SoundEffect.allCases.map { AudioCatalogue.cue(for: $0).assetName }
        #expect(names.count == 9)
        #expect(Set(names).count == 9)
    }

    @Test("Asset names are lowercase, extensionless resource names")
    func assetNamesAreWellFormed() throws {
        let pattern = try NSRegularExpression(pattern: "^[a-z][a-z0-9-]*$")
        for effect in SoundEffect.allCases {
            let name = AudioCatalogue.cue(for: effect).assetName
            let range = NSRange(name.startIndex..., in: name)
            #expect(
                pattern.firstMatch(in: name, range: range) != nil,
                "\(effect.rawValue) -> \(name) is not a bare lowercase asset name"
            )
        }
    }

    @Test("Every volume is a real relative level in 0...1")
    func volumesAreInRange() {
        for effect in SoundEffect.allCases {
            let volume = AudioCatalogue.cue(for: effect).volume
            #expect(volume >= 0 && volume <= 1, "\(effect.rawValue) volume \(volume) is out of range")
        }
    }

    @Test("The countdown tick repeats, so it sits under the one-shot win")
    func tickIsQuieterThanWin() {
        #expect(AudioCatalogue.cue(for: .countdownTick).volume < AudioCatalogue.cue(for: .win).volume)
    }

    @Test("Every physical move is felt as well as heard")
    func physicalEffectsHaveHaptics() {
        for effect in [SoundEffect.tilePlace, .tileRecall, .draw, .swap, .invalid] {
            #expect(AudioCatalogue.cue(for: effect).haptic != nil, "\(effect.rawValue) has no haptic")
        }
    }

    @Test("Menu taps are light; winning and losing hit hard")
    func hapticStrengthsAreGraded() {
        #expect(AudioCatalogue.cue(for: .menuTap).haptic == .light)
        #expect(AudioCatalogue.cue(for: .win).haptic == .heavy)
        #expect(AudioCatalogue.cue(for: .loss).haptic == .heavy)
    }

    @Test("A cue is a value — two lookups of the same effect are equal")
    func cuesAreValues() {
        #expect(AudioCatalogue.cue(for: .draw) == AudioCatalogue.cue(for: .draw))
        #expect(AudioCatalogue.cue(for: .draw) != AudioCatalogue.cue(for: .swap))
    }
}
