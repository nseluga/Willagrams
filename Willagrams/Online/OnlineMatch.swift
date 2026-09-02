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

    /// This device is not `roster[0]`, so it does not open the match — the
    /// frozen rule hands the pool, and with it the start, to the lowest
    /// `rawValue` in the roster, whoever happened to create the lobby.
    case notPoolHost

    /// No signed-in user to play as.
    case notAuthenticated
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
        if store == nil, let supabase = backend as? SupabaseBackend {
            store = await supabase.outcomeStore()
        }
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

    /// Opens the match from this device and hands back the live session.
    ///
    /// Refuses — writing nothing and sending nothing — unless the lobby holds
    /// exactly two players and this device is the one the frozen rule elects.
    public func start() async throws -> MatchSession {
        guard lobby.count == 2 else { throw OnlineMatchError.lobbyNotReady(lobby.count) }
        let roster = Self.roster(from: lobby)
        // Not `record.hostID`: whoever created the lobby, the pool — and so the
        // start — belongs to `roster[0]`, which both devices compute alike.
        guard HostPool.host(of: roster) == localPlayer else {
            throw OnlineMatchError.notPoolHost
        }
        let session = makeSession(roster: roster)
        // `startMatch` builds and sends the `.start` and applies it locally. The
        // seed is the row's, never a second draw.
        session.startMatch(
            seed: record.poolSeed,
            startingHandSize: Self.startingHandSize,
            countdownSeconds: Self.countdownSeconds,
            options: record.options
        )
        attachRecorder(to: session)
        return session
    }

    /// Builds the session a guest plays, and lets it take the host's `.start`
    /// off the transport by itself.
    ///
    /// The roster comes from `match_players` rather than from presence: it is
    /// the same set the host sends, sorted the same way, so both devices elect
    /// the same host and the arriving `.start` validates.
    public func awaitStart() async throws -> MatchSession {
        let rows = try await backend.players(inMatch: record.id)
        let roster = Self.roster(from: rows.map { PlayerID(rawValue: $0.playerID.uuidString) })
        let session = makeSession(roster: roster)
        attachRecorder(to: session)
        return session
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
