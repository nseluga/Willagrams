//
//  OnlineMatch.swift
//  Willagrams
//
//  The façade the shell will wire an online 1v1 to: create or join a lobby,
//  watch who is in it, and hand back a `MatchSession` that is already playing.
//
//  SDK-free by rule, exactly like `BackendContracts.swift`: everything here
//  goes through `BackendClient` and `MatchTransport`, so this file compiles and
//  tests with no Supabase project and no network.
//

import Foundation
import Observation
import WillagramsRules

/// Everything the façade itself can refuse to do.
///
/// Deliberately separate from `BackendError`: none of these came from the
/// server, and a screen shows a different thing for "wait for your friend" than
/// for "the network is gone".
public enum OnlineMatchError: Error, Sendable, Equatable {

    /// `start()` needs exactly two players this version. Carries what the lobby
    /// actually held, so a caller can say "waiting for 1 more".
    case lobbyNotReady(Int)

    /// No signed-in user to play as.
    case notAuthenticated
}

/// Closing out a lobby nobody is going to play.
///
/// A protocol beside `BackendClient` rather than a method on it: that file is
/// frozen, and abandoning is the one write a lobby screen makes that the match
/// itself never does. Both shipping clients conform — `SupabaseBackend` with an
/// `update ... set status = 'abandoned'` the row's own policy fences to the
/// host, `FakeBackend` by moving the row it holds.
public protocol MatchAbandoning: Sendable {

    /// Marks the `matches` row abandoned. A row that already left `lobby` is
    /// left exactly as it stands: a played match is closed out by the outcome
    /// recorder, never by whoever walked away from the screen.
    func abandonMatch(_ id: UUID) async throws
}

/// One online match, lobby through the moment play begins.
///
/// Create it with ``host(options:backend:)`` or ``join(code:backend:)``, watch
/// ``lobby``, then call ``start()`` (creator) or ``awaitStart()`` (guest) to get
/// the `MatchSession` the board screen drives.
@MainActor
@Observable
public final class OnlineMatch {

    // MARK: The two numbers a match opens with
    //
    // Solo uses the same pair (`ShellModel.soloHandSize` / `soloCountdownSeconds`).
    // They are declared here rather than read from the shell because `Online`
    // must not depend on the app's UI layer — but there is exactly one
    // definition on this side of that line, and every call site below reads it.

    /// Tiles each player opens with.
    public static let startingHandSize = 21

    /// Seconds of countdown before the deal.
    public static let countdownSeconds = 3

    // MARK: Identity

    /// The lobby row as the backend created or handed it back.
    public let record: MatchRecord

    /// This device's player, as the wire names it.
    public let localPlayer: PlayerID

    /// What a friend types to join. Six characters.
    public var inviteCode: String { record.inviteCode }

    /// Who is in the lobby right now, this device always included.
    ///
    /// Fed by the transport's presence stream, which is the only source that
    /// knows a peer has actually connected — the `match_players` row says
    /// somebody joined, not that they are still here.
    public private(set) var lobby: [PlayerID]

    // MARK: Injected

    @ObservationIgnored private let backend: any BackendClient
    @ObservationIgnored private let transport: any MatchTransport
    @ObservationIgnored private let dictionary: any WordList
    @ObservationIgnored private let dictionaryHash: String
    @ObservationIgnored private let outcomeStore: (any MatchOutcomeStore)?

    /// One countdown tick, handed straight to `MatchSession`. Injected so a
    /// test can open a match without waiting out `countdownSeconds` of real
    /// time — the same seam the match lane already uses.
    @ObservationIgnored
    private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void

    /// The recorder attached to the session this façade built, if there is a
    /// store to record into. Held so it outlives ``start()``.
    @ObservationIgnored public private(set) var recorder: MatchOutcomeRecorder?

    @ObservationIgnored private var presencePump: Task<Void, Never>?
    @ObservationIgnored private var recorderTask: Task<Void, Never>?

    /// Whether a `MatchSession` was handed out. What separates "a lobby nobody
    /// played" from "a match that ran": ``leave()`` abandons the row only in the
    /// first case, because in the second the outcome recorder owns it.
    @ObservationIgnored public private(set) var hasStarted = false

    /// The abandon this façade issues, or nil where the row cannot be closed
    /// out — the shell's cancel then still tears the channel down.
    @ObservationIgnored private var abandonTask: Task<Void, Never>?

    /// How many times the abandon is attempted before the row is left stale.
    ///
    /// Nobody waits on this write, but discarding its failure leaves a
    /// `matches` row stuck in `lobby` for good, with nothing surfaced. One
    /// attempt is a single dropped packet away from that.
    public static let abandonAttempts = 3

    /// How long to wait between those attempts. Injected `sleepFor` makes it
    /// free in tests.
    public static let abandonRetryDelay: Duration = .seconds(2)

    /// Whether the abandon landed: nil while it is still being attempted, and
    /// on a façade that never had a row to close out. False once every attempt
    /// has failed, which is a stale lobby row a human may have to clear.
    @ObservationIgnored public private(set) var abandonSucceeded: Bool?

    /// Waits out the abandon this façade issued, if any.
    ///
    /// Nothing in the app waits on it — the retry is fire-and-forget by design.
    /// A test has to, or it asserts on ``abandonSucceeded`` before the loop has
    /// run.
    func awaitAbandon() async { await abandonTask?.value }

    /// Set once ``leave()`` has run, so tearing a lobby down twice cannot issue
    /// two abandons or leave a transport that is already gone.
    @ObservationIgnored private var hasLeft = false

    private init(
        record: MatchRecord,
        localPlayer: PlayerID,
        backend: any BackendClient,
        transport: any MatchTransport,
        dictionary: any WordList,
        dictionaryHash: String,
        outcomeStore: (any MatchOutcomeStore)?,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void
    ) {
        self.record = record
        self.localPlayer = localPlayer
        self.backend = backend
        self.transport = transport
        self.dictionary = dictionary
        self.dictionaryHash = dictionaryHash
        self.outcomeStore = outcomeStore
        self.sleepFor = sleepFor
        // The local player is a member of their own lobby from the first frame:
        // nothing on the presence stream ever names this device.
        self.lobby = [localPlayer]
        watchLobby()
    }

    deinit {
        presencePump?.cancel()
        recorderTask?.cancel()
        // `abandonTask` is deliberately NOT cancelled. It captures the backend
        // and the row id rather than `self`, and the whole point of it is to
        // close out a row this façade is done with — cancelling it here would
        // abort the retry precisely when the screen tears the façade down,
        // which is the common case.
    }

    /// Tears this façade down: the presence pump, the recorder and the channel,
    /// and — for a lobby that never became a match — the `matches` row.
    ///
    /// Idempotent, and synchronous up to and including `transport.leave()`, so a
    /// screen that calls this before it moves cannot leave a live channel behind
    /// it. Only the abandon is a `Task`: it is a network write with nothing to
    /// wait for, and a lobby whose abandon never lands is a stale row, not a
    /// live channel.
    ///
    /// The session a started match handed out is not left here — `MatchSession`
    /// is owned by whoever took it, and leaving it twice is that owner's call.
    public func leave() {
        guard !hasLeft else { return }
        hasLeft = true
        presencePump?.cancel()
        presencePump = nil
        recorderTask?.cancel()
        recorderTask = nil
        transport.leave()
        guard !hasStarted, let abandoning = backend as? any MatchAbandoning else { return }
        let id = record.id
        let sleepFor = sleepFor
        abandonTask = Task { [weak self] in
            for attempt in 1...Self.abandonAttempts {
                do {
                    try await abandoning.abandonMatch(id)
                    self?.abandonSucceeded = true
                    return
                } catch {
                    guard attempt < Self.abandonAttempts else { break }
                    // A cancelled sleep must not spin the loop: it would burn
                    // every remaining attempt in one pass and report failure.
                    try? await sleepFor(Self.abandonRetryDelay)
                    guard !Task.isCancelled else { return }
                }
            }
            self?.abandonSucceeded = false
        }
    }

    // MARK: - Entry points

    /// Creates a lobby and opens its channel.
    ///
    /// The seed is drawn once, here, and lives on the `matches` row from then
    /// on — ``start()`` sends `record.poolSeed` and never a second draw, so the
    /// two devices and the row all agree about the shuffle.
    public static func host(
        options: MatchOptions,
        backend: any BackendClient,
        dictionary: (any WordList)? = nil,
        dictionaryHash: String = MatchOptions.standardDictionaryHash,
        outcomeStore: (any MatchOutcomeStore)? = nil,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) async throws -> OnlineMatch {
        guard let userID = await backend.currentUserID else {
            throw OnlineMatchError.notAuthenticated
        }
        // `matches.seed` is a Postgres `bigint`, so the draw is over the
        // non-negative half. `MatchRecord.poolSeed` widens it back.
        let seed = Int64.random(in: 0...Int64.max)
        let record = try await backend.createMatch(options: options, seed: seed)
        return try await make(
            record: record,
            userID: userID,
            backend: backend,
            dictionary: dictionary,
            dictionaryHash: dictionaryHash,
            outcomeStore: outcomeStore,
            sleepFor: sleepFor
        )
    }

    /// Joins a lobby by its invite code and opens its channel.
    public static func join(
        code: String,
        backend: any BackendClient,
        dictionary: (any WordList)? = nil,
        dictionaryHash: String = MatchOptions.standardDictionaryHash,
        outcomeStore: (any MatchOutcomeStore)? = nil,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) async throws -> OnlineMatch {
        guard let userID = await backend.currentUserID else {
            throw OnlineMatchError.notAuthenticated
        }
        let record = try await backend.joinMatch(inviteCode: code)
        return try await make(
            record: record,
            userID: userID,
            backend: backend,
            dictionary: dictionary,
            dictionaryHash: dictionaryHash,
            outcomeStore: outcomeStore,
            sleepFor: sleepFor
        )
    }

    private static func make(
        record: MatchRecord,
        userID: UUID,
        backend: any BackendClient,
        dictionary: (any WordList)?,
        dictionaryHash: String,
        outcomeStore: (any MatchOutcomeStore)?,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void
    ) async throws -> OnlineMatch {
        let localPlayer = PlayerID(rawValue: userID.uuidString)
        let transport = try await backend.transport(for: record, as: localPlayer)
        // `outcomeStore()` is on the concrete client, not the protocol, and
        // `BackendContracts.swift` is frozen — so it is injected, and the cast
        // is only the default for a caller that did not.
        var store = outcomeStore
        // The concrete client only exists where the SDK does. `Tests/ShellTests`
        // compiles this file with the SDK-free half of `Online` and no
        // `SupabaseBackend` to name, so the default is fenced on the SDK rather
        // than on a build configuration.
        #if canImport(PostgREST)
        if store == nil, let supabase = backend as? SupabaseBackend {
            store = await supabase.outcomeStore()
        }
        #endif
        return OnlineMatch(
            record: record,
            localPlayer: localPlayer,
            backend: backend,
            transport: transport,
            dictionary: dictionary ?? defaultDictionary(),
            dictionaryHash: dictionaryHash,
            outcomeStore: store,
            sleepFor: sleepFor
        )
    }

    /// The bundled list, or an empty one where there is no bundle to load from
    /// (a SwiftPM test run). A caller that cares injects its own.
    private static func defaultDictionary() -> any WordList {
        (try? EnableWordList()) ?? EnableWordList(words: [])
    }

    // MARK: - The lobby

    /// Consumes the transport's presence stream until a session takes it over.
    ///
    /// `MatchTransport` allows exactly one consumer per stream per endpoint, so
    /// this pump is cancelled the moment a `MatchSession` is built — the session
    /// is the consumer from then on.
    ///
    /// ponytail: a `.disconnected` that lands in the microseconds between that
    /// cancel and the session's own pump starting is dropped. Harmless here —
    /// `MatchSession.presence(of:)` reads absent as present and the peer's next
    /// state change is delivered normally. Hand the buffered element across if a
    /// transport is ever built that reports drops only once.
    private func watchLobby() {
        let states = transport.peerConnectionStates
        presencePump = Task { @MainActor [weak self] in
            for await state in states {
                guard let self else { return }
                switch state {
                case let .connected(player):
                    guard player != localPlayer, !lobby.contains(player) else { continue }
                    lobby.append(player)
                case let .disconnected(player):
                    guard player != localPlayer else { continue }
                    lobby.removeAll { $0 == player }
                }
            }
        }
    }

    // MARK: - Opening the match

    /// Hands back the live session for the device that created the lobby.
    ///
    /// Refuses — writing nothing and sending nothing — unless the lobby holds
    /// exactly two players.
    ///
    /// Creating the lobby is not what opens the match: the frozen rule gives
    /// the pool, and with it the `.start`, to `roster[0]`. A creator that does
    /// not sort first gets a perfectly live session that plays the receiving
    /// side, rather than an error — a match must not be undealable because two
    /// UUIDs happened to fall the wrong way round.
    public func start() async throws -> MatchSession {
        guard lobby.count == 2 else { throw OnlineMatchError.lobbyNotReady(lobby.count) }
        let roster = Self.roster(from: lobby)
        let session = makeSession(roster: roster)
        // Never `record.hostID`. Both devices compute this from the same sorted
        // roster, so exactly one of them opens and there is no negotiation.
        if HostPool.host(of: roster) == localPlayer { open(session) }
        attachRecorder(to: session)
        return session
    }

    /// Hands back the live session for the device that joined by code.
    ///
    /// The roster comes from `match_players` rather than from presence: it is
    /// the same set that travels on `.start`, sorted the same way, so both
    /// devices elect the same opener and the message validates on arrival.
    ///
    /// Opens the match itself when this device is `roster[0]`; otherwise the
    /// session takes the opener's `.start` off the transport by itself.
    public func awaitStart() async throws -> MatchSession {
        let rows = try await backend.players(inMatch: record.id)
        let roster = Self.roster(from: rows.map { PlayerID(rawValue: $0.playerID.uuidString) })
        guard roster.count == 2 else { throw OnlineMatchError.lobbyNotReady(roster.count) }
        let session = makeSession(roster: roster)
        if HostPool.host(of: roster) == localPlayer { open(session) }
        attachRecorder(to: session)
        return session
    }

    /// Sends the `.start` and applies it locally, from the one device the
    /// roster elects.
    ///
    /// `MatchSession.startMatch` carries its own `roster[0]` guard, so this is
    /// belt and braces rather than the only rule — but the seed and the two
    /// constants are read here, in one place, whichever entry point called.
    private func open(_ session: MatchSession) {
        session.startMatch(
            seed: record.poolSeed,
            startingHandSize: Self.startingHandSize,
            countdownSeconds: Self.countdownSeconds,
            options: record.options
        )
    }

    /// The roster every device computes, from whatever order it learned the
    /// players in — presence here, membership rows on the guest.
    ///
    /// Ascending by `rawValue`, which is what makes `roster[0]` the same player
    /// on both devices and what `MatchMessage.validatedStart` demands. One
    /// definition, used by both entry points: two sorts is how two devices end
    /// up electing two hosts.
    static func roster(from players: [PlayerID]) -> [PlayerID] {
        players.sorted { $0.rawValue < $1.rawValue }
    }

    private func makeSession(roster: [PlayerID]) -> MatchSession {
        presencePump?.cancel()
        presencePump = nil
        hasStarted = true
        return MatchSession(
            transport: transport,
            roster: roster,
            dictionary: dictionary,
            dictionaryHash: dictionaryHash,
            sleepFor: sleepFor
        )
    }

    /// Starts recording what the match does, if this façade was given somewhere
    /// to record it. No store — a fake backend, a test — records nothing rather
    /// than failing the match.
    private func attachRecorder(to session: MatchSession) {
        guard let outcomeStore else { return }
        let recorder = MatchOutcomeRecorder(
            record: record,
            localPlayer: localPlayer,
            session: session,
            store: outcomeStore
        )
        self.recorder = recorder
        recorderTask = Task { @MainActor in await recorder.run() }
    }
}
