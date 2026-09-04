import Audio
import Foundation
import Match
import Settings
import Testing
import WillagramsRules

@testable import Shell

/// The fake backend is the shell's stand-in for the anonymous session: the real
/// one only exists on `SupabaseBackend`, and only in Debug.
extension FakeBackend: ShellSignIn {
    public func signIn() async throws -> Profile {
        try await signInWithApple(idToken: "shell-tests", nonce: "shell-tests")
    }
}

/// An `AudioPlayer` that records what it was asked to play, so a test can see
/// that the shell reached the player the root handed it and not one of its own.
final class RecordingAudioPlayer: AudioPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var played: [SoundEffect] = []
    private var muted: Bool

    init(muted: Bool = false) { self.muted = muted }

    var effects: [SoundEffect] { lock.withLock { played } }
    var isMuted: Bool { lock.withLock { muted } }
    func play(_ effect: SoundEffect) { lock.withLock { played.append(effect) } }
    func impact(_ strength: HapticStrength) {}
    func setMuted(_ muted: Bool) { lock.withLock { self.muted = muted } }
}

/// A sign-in that always fails the same way.
private struct FailingSignIn: ShellSignIn {
    let error: any Error
    func signIn() async throws -> Profile { throw error }
}

/// A sign-in that hangs until ``release()``, and records that it was cancelled.
///
/// Suspends on a continuation rather than polling: a sleeping or spinning task
/// that outlives its test perturbs every other suite in the run.
private final class GateSignIn: ShellSignIn, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, any Error>?

    var wasCancelled: Bool { lock.withLock { cancelled } }
    private var isWaiting: Bool { lock.withLock { waiter != nil } }

    /// Yields until the sign-in has actually parked on the continuation. A
    /// task cancelled before it starts never runs its cancellation handler, so
    /// a teardown test that does not wait for this asserts nothing.
    func untilSuspended() async {
        for _ in 0..<100_000 where !isWaiting { await Task.yield() }
    }

    /// Lets the sign-in finish. Safe to call twice, and safe to call when
    /// nothing is waiting yet.
    func release() {
        let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
            released = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    private func recordCancellation() {
        let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
            cancelled = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(throwing: CancellationError())
    }

    func signIn() async throws -> Profile {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Next { case finish, cancel, wait }
                let next: Next = lock.withLock {
                    if released { return .finish }
                    if cancelled { return .cancel }
                    waiter = continuation
                    return .wait
                }
                switch next {
                case .finish: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            recordCancellation()
        }
        return Profile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            displayName: "Player 0001",
            friendCode: "AAAA1111",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

@MainActor
@Suite("Shell services and launch sign-in", .serialized)
struct ShellServicesTests {

    @Test("A fake backend's sign-in publishes a profile and clears the reason")
    func fakeSignInPublishesProfile() async {
        let backend = FakeBackend()
        let shell = ShellModel(services: ShellServices(backend: backend, signIn: backend))

        await shell.signInTask?.value
        #expect(shell.currentProfile != nil)
        #expect(shell.onlineUnavailableReason == nil)
    }

    @Test("A sign-in that throws .offline leaves no profile and a readable reason")
    func offlineSignInPublishesReason() async {
        let shell = ShellModel(
            services: ShellServices(signIn: FailingSignIn(error: BackendError.offline))
        )

        await shell.signInTask?.value
        #expect(shell.currentProfile == nil)
        #expect(shell.onlineUnavailableReason?.isEmpty == false)
        // Distinguishable from the pending copy, or the menu would say "signing
        // in" forever after a failure.
        #expect(shell.onlineUnavailableReason != ShellModel.signingInReason)
        #expect(shell.onlineUnavailableReason == ShellModel.onlineUnavailableReason(for: BackendError.offline))
    }

    @Test("While sign-in is pending the reason is the pending copy")
    func pendingPublishesSigningIn() async {
        let gate = GateSignIn()
        let shell = ShellModel(services: ShellServices(signIn: gate))

        #expect(shell.currentProfile == nil)
        #expect(shell.onlineUnavailableReason == ShellModel.signingInReason)

        // Nothing suspended is left behind for the rest of the run.
        gate.release()
        await shell.signInTask?.value
        #expect(shell.currentProfile != nil)
    }

    @Test("Solo Practice starts while sign-in is still pending")
    func soloPracticeDoesNotWaitOnSignIn() async {
        let gate = GateSignIn()
        let shell = ShellModel(sleepFor: { _ in }, services: ShellServices(signIn: gate))

        #expect(shell.startSoloPractice(seed: 7))
        #expect(shell.route != .menu)
        // Still pending: the match started without the session.
        #expect(shell.currentProfile == nil)
        #expect(shell.onlineUnavailableReason == ShellModel.signingInReason)

        gate.release()
        await shell.signInTask?.value
        #expect(shell.currentProfile != nil)
    }

    @Test("The sign-in task is cancelled when the model goes away")
    func teardownCancelsSignIn() async {
        let gate = GateSignIn()
        var shell: ShellModel? = ShellModel(services: ShellServices(signIn: gate))
        #expect(shell?.onlineUnavailableReason == ShellModel.signingInReason)
        await gate.untilSuspended()

        shell = nil
        #expect(gate.wasCancelled)
    }

    @Test("A build with no sign-in publishes a reason and never a profile")
    func noSignInIsADisabledState() async {
        let shell = ShellModel()

        #expect(shell.currentProfile == nil)
        #expect(shell.onlineUnavailableReason == ShellModel.noSignInReason)
        #expect(shell.onlineUnavailableReason?.isEmpty == false)
    }

    @Test("Every backend failure maps to one non-empty line, and offline says so")
    func everyErrorMapsToCopy() {
        for error in [
            BackendError.offline, .notAuthenticated, .notFound, .alreadyExists,
            .blocked, .matchFull, .permissionDenied,
        ] {
            #expect(ShellModel.onlineUnavailableReason(for: error).isEmpty == false)
            #expect(ShellModel.onlineUnavailableReason(for: error) != ShellModel.signingInReason)
        }
        #expect(ShellModel.onlineUnavailableReason(for: BackendError.offline)
            != ShellModel.onlineUnavailableReason(for: BackendError.permissionDenied))
        // A non-backend error still gets a line rather than an empty label.
        #expect(ShellModel.onlineUnavailableReason(for: CancellationError()).isEmpty == false)
    }

    @Test("The services value carries what the root built")
    func servicesArePassedThrough() {
        let backend = FakeBackend()
        let audio = RecordingAudioPlayer(muted: true)
        // In-memory: a suite the app never uses, so nothing here can read or
        // write the real defaults.
        let store = SettingsStore(defaults: UserDefaults(suiteName: "shell-services-tests")!)
        let shell = ShellModel(
            services: ShellServices(backend: backend, audio: audio, settings: store, signIn: nil)
        )

        #expect(shell.services.backend != nil)
        #expect(shell.services.audio.isMuted)
        #expect(shell.services.settings != nil)
        #expect(shell.services.signIn == nil)

        // The value carries the identity, not a copy: a cue played through the
        // shell's player lands in the one the root built.
        shell.services.audio.play(.tilePlace)
        #expect(audio.effects == [.tilePlace])
    }
}
