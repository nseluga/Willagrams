import Testing
@testable import Audio

// The fixture for the audio seam. It proves the shape lanes compile against,
// not that anything makes noise — `SilentAudioPlayer` deliberately does not.

@Suite("Audio seam")
struct AudioSeamTests {

    @Test("Every moment the game makes a sound has exactly one case")
    func caseCount() {
        // A case added or removed here is a contract change, not a lane edit:
        // `shell` writes a call site per case and `audio` ships an asset per
        // case, so the two only stay in step if the count is pinned.
        #expect(SoundEffect.allCases.count == 9)
    }

    @Test("Raw values are unique, so no two moments share an asset key")
    func rawValuesAreUnique() {
        let raws = Set(SoundEffect.allCases.map(\.rawValue))
        #expect(raws.count == SoundEffect.allCases.count)
    }

    @Test("Raw values are the case names, so an asset table can key off them")
    func rawValuesAreStable() {
        #expect(SoundEffect.tilePlace.rawValue == "tilePlace")
        #expect(SoundEffect.countdownTick.rawValue == "countdownTick")
        #expect(SoundEffect.menuTap.rawValue == "menuTap")
    }

    @Test("The silent player reports back the mute it was given")
    func muteRoundTrips() {
        let player = SilentAudioPlayer()
        #expect(player.isMuted == false)

        player.setMuted(true)
        #expect(player.isMuted == true)

        player.setMuted(false)
        #expect(player.isMuted == false)
    }

    @Test("The silent player starts muted when it is built that way")
    func initialMute() {
        #expect(SilentAudioPlayer(muted: true).isMuted == true)
    }

    @Test("Playing every effect and every haptic is a no-op that never traps")
    func playingIsHarmless() {
        // The whole point of the seam: a call site can fire sound into a player
        // that has no audio engine behind it and nothing goes wrong.
        let player = SilentAudioPlayer()
        for effect in SoundEffect.allCases {
            player.play(effect)
        }
        for strength in [HapticStrength.light, .medium, .heavy] {
            player.impact(strength)
        }
        player.setMuted(true)
        for effect in SoundEffect.allCases {
            player.play(effect)
        }
        #expect(player.isMuted == true)
    }
}
