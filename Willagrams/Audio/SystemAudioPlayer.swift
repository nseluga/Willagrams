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
    /// `lock` only. Bumped when the app backgrounds, which strands every sound
    /// already scheduled but not yet fired — a delayed cue that comes due while
    /// the app is away belongs to a moment the player is no longer watching.
    private var generation = 0

    private var backgroundObserver: NSObjectProtocol?

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

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.bumpGeneration() }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    private func bumpGeneration() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    private var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
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

    /// How long after the call a cue's *sound* is due, in seconds.
    ///
    /// The board animates a snap over `Motion.snapDuration` and a deal over
    /// `Motion.dealDuration`, so a sound fired at gesture-release plays while
    /// the tile is still travelling. These are read from `DesignTokens`, never
    /// copied: retuning the animation there retunes the sound with it.
    ///
    /// Exhaustive on purpose — a tenth `SoundEffect` is a compile error here
    /// rather than a cue that silently defaults to immediate.
    private static func delay(for effect: SoundEffect) -> TimeInterval {
        switch effect {
        case .tilePlace, .tileRecall: return DesignTokens.Motion.snapDuration
        case .draw: return DesignTokens.Motion.dealDuration
        case .swap, .invalid, .countdownTick, .win, .loss, .menuTap: return 0
        }
    }

    public func play(_ effect: SoundEffect) {
        let cue = AudioCatalogue.cue(for: effect)
        // The haptic still fires now, on the caller's thread. Only the sound is
        // scheduled: the haptic belongs to the gesture the player just made,
        // the sound belongs to the tile arriving at the end of the animation.
        if let haptic = cue.haptic { impact(haptic) }
        guard !isMuted else { return }
        // Computed on the caller's thread: `queue` is serial, so a cue enqueued
        // behind a cold preload would otherwise fire seconds after the moment
        // that belongs to it.
        //
        // This is the cue's *intended* fire time, not the moment `play` was
        // called — `emit` measures lateness against it, so a deliberate delay
        // is never mistaken for a stalled queue (see `emit`).
        // Only a haptic-paired cue is worth dropping when late (see `emit`);
        // a sound-only cue has no second event to desync from, so it is stampless.
        let delay = Self.delay(for: effect)
        let dueAt = DispatchTime.now() + delay
        let stamp = cue.haptic == nil ? nil : dueAt
        let scheduledGeneration = currentGeneration
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            emit(effect, volume: cue.volume, dueAt: stamp, generation: scheduledGeneration)
        }
        // Zero-delay cues keep the plain `async` enqueue, and with it the
        // ordering behind `preload` that the comment in `init` relies on.
        if delay > 0 {
            queue.asyncAfter(deadline: dueAt, execute: work)
        } else {
            queue.async(execute: work)
        }
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

    /// A *haptic-paired* cue this late is worse than no cue: its haptic already
    /// fired on the caller's thread, so playing now buzzes then clicks as two
    /// events. A sound-only cue (`dueAt == nil`) is never dropped — late is
    /// unnoticeable, silent is a bug.
    ///
    /// Measured from when the cue was *due*, not from when `play` was called:
    /// a cue with a `delay(for:)` is deliberately later than its haptic, and
    /// measuring from the call would drop `draw` every single time.
    private static let staleAfterNanos: UInt64 = 200_000_000

    private func emit(_ effect: SoundEffect, volume: Float, dueAt: DispatchTime?, generation: Int) {
        // The app backgrounded between the schedule and now; this sound belongs
        // to a moment nobody is looking at any more.
        guard generation == currentGeneration else { return }
        if let dueAt {
            let now = DispatchTime.now().uptimeNanoseconds
            let due = dueAt.uptimeNanoseconds
            // `asyncAfter` may fire a hair early, and `&-` on unsigned nanos
            // would turn that into a huge "lateness". Not-yet-due is never stale.
            let lateBy = now > due ? now - due : 0
            guard lateBy < Self.staleAfterNanos else { return }
        }
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
        // Both calls are retried on the next cue rather than latched: staying
        // on the default `.soloAmbient` would silence the player's own music,
        // and an inactive session plays nothing at all.
        guard (try? session.setCategory(.ambient, mode: .default, options: [])) != nil,
              (try? session.setActive(true)) != nil else { return }
        sessionReady = true
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
