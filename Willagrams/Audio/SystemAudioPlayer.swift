//
//  SystemAudioPlayer.swift
//  Willagrams
//
//  The real `AudioPlayer`. Everything platform-specific in the audio lane
//  lives here, behind one guard — `Tests/AudioTests/AudioSrc` symlinks this
//  whole directory onto a macOS test host, so an unguarded AVFoundation or
//  UIKit import anywhere under `Willagrams/Audio/**` breaks the audio gate.
//
//  The guard therefore wraps the imports too, not just the type.
//

#if canImport(UIKit)

import AVFoundation
import Foundation
import UIKit

/// Plays the catalogue's cues through `AVAudioPlayer` and the Taptic Engine.
///
/// Nothing here throws or blocks: a missing asset, a refused session and a
/// silenced device are all the same outcome to a caller — no sound, game
/// continues — so every platform call is `try?` and every real unit of work
/// happens on a private serial queue.
public final class SystemAudioPlayer: AudioPlayer, @unchecked Sendable {

    /// Simultaneous voices per asset. Two tiles placed in quick succession
    /// have to overlap rather than restart one shared player, and three is
    /// past the point a human hears the difference.
    ///
    /// ponytail: fixed pool, allocated once. Grow it only if a cue is ever
    /// audibly cut short at four-deep overlap.
    private static let voicesPerAsset = 3

    /// Extensions tried, in order, for a catalogue `assetName`. The audio
    /// files do not exist yet, so this deliberately resolves to nothing today.
    private static let assetExtensions = ["caf", "wav", "m4a", "aiff", "mp3"]

    /// Every `AVAudioPlayer` and the session flag are touched here and only
    /// here, which is also what keeps `play` off the caller's thread.
    private let queue = DispatchQueue(label: "com.willagrams.audio", qos: .userInitiated)

    /// Resolved in `init` so `Bundle` never crosses onto `queue`.
    private let urls: [SoundEffect: URL]

    /// `queue` only.
    private var voices: [SoundEffect: [AVAudioPlayer]] = [:]
    /// `queue` only. The session is configured and activated on first sound,
    /// never at init — launching the app must not touch another app's audio.
    private var sessionReady = false

    private let lock = NSLock()
    private var muted: Bool

    /// - Parameters:
    ///   - bundle: where the assets are looked up. Injected so a test can
    ///     hand over a bundle holding none of them.
    ///   - muted: starting mute state.
    public init(bundle: Bundle = .main, muted: Bool = false) {
        self.muted = muted

        var found: [SoundEffect: URL] = [:]
        for effect in SoundEffect.allCases {
            let name = AudioCatalogue.cue(for: effect).assetName
            for ext in Self.assetExtensions {
                if let url = bundle.url(forResource: name, withExtension: ext) {
                    found[effect] = url
                    break
                }
            }
        }
        self.urls = found

        // Decoding on the caller's thread would stall launch. The queue is
        // serial, so this lands before any `play` dispatched after init.
        queue.async { [weak self] in self?.preload() }
    }

    public var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    public func setMuted(_ muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.muted = muted
    }

    public func play(_ effect: SoundEffect) {
        let cue = AudioCatalogue.cue(for: effect)
        if let haptic = cue.haptic { impact(haptic) }
        guard !isMuted else { return }
        // Stamped on the caller's thread: `queue` is serial, so a cue enqueued
        // behind a cold preload would otherwise fire seconds after the haptic
        // that belongs to it.
        let requestedAt = DispatchTime.now()
        queue.async { [weak self] in self?.emit(effect, volume: cue.volume, requestedAt: requestedAt) }
    }

    /// Fires regardless of mute: the mute control is sound-only, and iOS
    /// already gates haptics separately through System Haptics.
    public func impact(_ strength: HapticStrength) {
        guard Thread.isMainThread else {
            Task { @MainActor in Self.fire(strength) }
            return
        }
        MainActor.assumeIsolated { Self.fire(strength) }
    }

    // MARK: - Sound, on `queue`

    private func preload() {
        for (effect, url) in urls {
            let players = (0..<Self.voicesPerAsset).compactMap { _ -> AVAudioPlayer? in
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                player.prepareToPlay()
                return player
            }
            if !players.isEmpty { voices[effect] = players }
        }
    }

    /// A cue this late is worse than no cue: its haptic already fired on the
    /// caller's thread, so playing now buzzes then clicks as two events.
    private static let staleAfterNanos: UInt64 = 200_000_000

    private func emit(_ effect: SoundEffect, volume: Float, requestedAt: DispatchTime) {
        guard DispatchTime.now().uptimeNanoseconds &- requestedAt.uptimeNanoseconds
                < Self.staleAfterNanos else { return }
        // No asset on disk is the normal case until the audio files land.
        guard let players = voices[effect], !players.isEmpty else { return }
        activateSessionIfNeeded()

        // The first idle voice; if all are busy, restart the oldest rather
        // than allocate on the hot path.
        let player = players.first { !$0.isPlaying } ?? players[0]
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    private func activateSessionIfNeeded() {
        guard !sessionReady else { return }
        let session = AVAudioSession.sharedInstance()
        // `.ambient`, never `.playback`: the game obeys the physical silent
        // switch and never interrupts music the player already had going.
        // A refused category is retried on the next cue rather than latched —
        // staying on the default `.soloAmbient` would silence that music.
        guard (try? session.setCategory(.ambient, mode: .default, options: [])) != nil else { return }
        sessionReady = true
        try? session.setActive(true)
    }

    #if DEBUG
    /// Test-only. Runs `body` on `queue` with the voice pool, so a harness can
    /// read `AVAudioPlayer` state without racing `preload`/`emit` — both the
    /// dictionary and the players are queue-confined and neither is thread-safe.
    public func debugVoices<T>(_ effect: SoundEffect, _ body: ([AVAudioPlayer]) -> T) -> T {
        queue.sync { body(voices[effect] ?? []) }
    }
    #endif

    // MARK: - Haptics, on the main actor

    /// Warmed and held, matching `TileFeedback`: a generator built and fired in
    /// the same breath wakes the Taptic Engine on the event itself and lands
    /// the buzz late.
    @MainActor private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    @MainActor private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)

    @MainActor
    private static func fire(_ strength: HapticStrength) {
        let generator: UIImpactFeedbackGenerator
        switch strength {
        case .light: generator = lightGenerator
        case .medium: generator = mediumGenerator
        case .heavy: generator = heavyGenerator
        }
        generator.impactOccurred()
        // Re-arm for the next one; cues cluster.
        generator.prepare()
    }
}

#endif
