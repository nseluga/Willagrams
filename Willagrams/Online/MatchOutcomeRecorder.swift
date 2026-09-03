//
//  MatchOutcomeRecorder.swift
//  Willagrams
//
//  What a finished match leaves behind: the `matches` row closed out by the
//  player who created it, and one stats bump per player on their own
//  `profiles` row.
//
//  ## Why the database is behind a protocol here
//
//  Every rule in this file is false-negative shaped — "exactly once", "never
//  decrements", "the guest issues no `matches` update at all". Each of those
//  looks identical to a clean run once it stops firing, and none of them can be
//  seen from the outside of a PostgREST call. So the whole database dependency
//  is ``MatchOutcomeStore``: three methods, SDK-free, and a test double that
//  records the calls is what makes the rules decidable with no project.
//
//  The Supabase-backed conformance lives in `SupabaseBackend+Outcome.swift`,
//  which is the only half of this that needs a network to prove.
//
//  ## The two things the client, not the database, has to get right
//
//  1. **Only the creator touches `matches`.** `matches_update_host` refuses
//     everyone else, and PostgREST reports that refusal as *zero rows updated*
//     — a 200, not a 42501. A guest that issued the update would see success.
//     So the gate is here, and ``isCreator`` is checked before every write.
//  2. **Exactly one stats write per player per match.** The session's state is
//     observed, and an observation can fire any number of times after the match
//     ends. Both latches below are set *before* the `await`, never after.
//

import Foundation
import Observation
import WillagramsRules

// MARK: - The seam

/// The one write the recorder ever makes to a `matches` row.
///
/// Two cases rather than an optional-riddled patch: `matches` constrains
/// `started_at`, `finished_at` and `winner_id` against `status`, so a partial
/// write is a rejected write.
public enum MatchOutcomeUpdate: Sendable, Equatable {
    case playing(startedAt: Date)
    case finished(finishedAt: Date, winnerID: UUID)
}

/// The four counters this recorder owns on a `profiles` row.
///
/// A whole new value rather than a delta: the increment is computed from the
/// row as it was read, so what reaches the database is always a value that
/// already satisfies `matches_won <= matches_played` and the non-negativity
/// checks. `fastestWinSeconds` is `encodeIfPresent` by synthesis, so a `nil`
/// omits the key rather than nulling a record the player already holds.
public struct ProfileStats: Sendable, Equatable, Encodable {

    public var matchesPlayed: Int
    public var matchesWon: Int
    public var tilesPlaced: Int
    public var fastestWinSeconds: Int?

    public enum CodingKeys: String, CodingKey {
        case matchesPlayed = "matches_played"
        case matchesWon = "matches_won"
        case tilesPlaced = "tiles_placed"
        case fastestWinSeconds = "fastest_win_seconds"
    }

    public init(matchesPlayed: Int, matchesWon: Int, tilesPlaced: Int, fastestWinSeconds: Int?) {
        self.matchesPlayed = matchesPlayed
        self.matchesWon = matchesWon
        self.tilesPlaced = tilesPlaced
        self.fastestWinSeconds = fastestWinSeconds
    }

    /// The row after one finished match, from the row before it.
    ///
    /// Total and pure, so the whole rule set is decidable with no project and
    /// no session. Nothing here can decrease: every counter is `current + n`
    /// with `n >= 0`, and `fastest_win_seconds` only ever moves down towards a
    /// better time, which is the one place "lower is better" is not a decrement
    /// of a tally.
    public static func after(
        _ current: Profile,
        won: Bool,
        tilesPlaced: Int,
        elapsedSeconds: Int
    ) -> ProfileStats {
        ProfileStats(
            matchesPlayed: current.matchesPlayed + 1,
            matchesWon: current.matchesWon + (won ? 1 : 0),
            // A negative count could only be a bug above, and it would take the
            // row's own tally down with it.
            tilesPlaced: current.tilesPlaced + max(0, tilesPlaced),
            fastestWinSeconds: fastestWin(
                current: current.fastestWinSeconds, won: won, elapsedSeconds: elapsedSeconds
            )
        )
    }

    /// The whole `fastest_win_seconds` rule, as one function with one meaning.
    ///
    /// - A loss never touches it, whatever the elapsed time was.
    /// - A win with nothing recorded sets it.
    /// - A win sets it only if it beats what is there.
    ///
    /// The floor of 1 is the database's, not a preference: `fastest_win_seconds`
    /// is `null or > 0`, and a match won inside a second rounds to zero.
    public static func fastestWin(current: Int?, won: Bool, elapsedSeconds: Int) -> Int? {
        guard won else { return current }
        let elapsed = max(1, elapsedSeconds)
        guard let current else { return elapsed }
        return elapsed < current ? elapsed : current
    }
}

/// Everything ``MatchOutcomeRecorder`` asks of the database.
///
/// Three methods, and the read is one of them on purpose: a stats bump is an
/// increment on a value that was read, never a blind write of a number this
/// process guessed.
///
/// SDK-free by rule — this file must never import `PostgREST`.
public protocol MatchOutcomeStore: Sendable {

    /// Updates the `matches` row. Only ever called on the creator's device.
    func updateMatch(_ id: UUID, _ update: MatchOutcomeUpdate) async throws

    /// The row as it stands, which is what the increment is computed from.
    func profile(_ id: UUID) async throws -> Profile

    /// Writes the four counters back. Only ever the caller's own row.
    func updateProfile(_ id: UUID, _ stats: ProfileStats) async throws
}

// MARK: - The recorder

/// Watches one `MatchSession` and records what the match did.
///
/// One per match per device. Create it before play begins and call ``run()``;
/// it returns once there is nothing left to record.
@MainActor
public final class MatchOutcomeRecorder {

    private let record: MatchRecord
    private let localPlayer: PlayerID
    private let session: MatchSession
    private let store: any MatchOutcomeStore
    private let now: @Sendable () -> Date

    /// When this device saw the match reach `.playing`, on the local clock.
    ///
    /// Also the gate on everything else: nothing is written before it is set,
    /// which is exactly the "a match that never started leaves no trace" rule.
    public private(set) var startedAt: Date?

    /// Set before the `await`, never after. Two observations of the same
    /// finished match must not both get past these.
    private var didMarkPlaying = false
    private var didMarkFinished = false
    private var didRecordStats = false

    /// The last write that failed, for a caller that wants to say so.
    ///
    /// A failed write is not retried: retrying is how "exactly once" becomes
    /// "at least once", and a lost stats bump is worth less than a doubled one.
    /// ponytail: no retry, no queue — add one only with an idempotency key on
    /// the row, never with a second attempt from here.
    public private(set) var lastError: (any Error)?

    /// Whether this device created the match. The only device that may write to
    /// the `matches` row; see the header.
    public var isCreator: Bool { Self.uuid(localPlayer) == record.hostID }

    /// Nothing further can be recorded for this match.
    public var isDone: Bool {
        didRecordStats || (session.isMatchOver && session.winner == nil)
    }

    public init(
        record: MatchRecord,
        localPlayer: PlayerID,
        session: MatchSession,
        store: any MatchOutcomeStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.record = record
        self.localPlayer = localPlayer
        self.session = session
        self.store = store
        self.now = now
    }

    /// `PlayerID.rawValue` carries `Profile.id.uuidString`; anything else is
    /// not a player of this match and is never written for.
    static func uuid(_ player: PlayerID) -> UUID? { UUID(uuidString: player.rawValue) }

    // MARK: One observation

    /// Records whatever the session's current state now makes recordable.
    ///
    /// The whole decision procedure, and safe to call any number of times: the
    /// latches, not the caller, are what make each write happen once.
    public func sync() async {
        guard let startedAt else {
            // The match has not begun on this device. Not "not yet finished" —
            // a session that never reaches `.playing` leaves the `matches` row
            // in `lobby` with null timestamps and both stats rows untouched,
            // and this is the line that holds that.
            //
            // ponytail: a `.playing` this device never observes — a coalesced
            // jump straight to `.finished` — records nothing. Fix by latching a
            // start on the *first* observation of any non-countdown status, if
            // that is ever seen in the wild.
            guard session.state.status == .playing else { return }
            let started = now()
            self.startedAt = started
            if isCreator, !didMarkPlaying {
                didMarkPlaying = true
                await write { try await store.updateMatch(record.id, .playing(startedAt: started)) }
            }
            return
        }

        // A match that ended with nobody named — a peer that never came back —
        // is not a result. Nothing is written for it, by anyone.
        guard let winner = session.winner, let winnerID = Self.uuid(winner) else { return }

        if isCreator, !didMarkFinished {
            didMarkFinished = true
            await write {
                try await store.updateMatch(record.id, .finished(finishedAt: now(), winnerID: winnerID))
            }
        }

        guard !didRecordStats, let localID = Self.uuid(localPlayer) else { return }
        didRecordStats = true
        let elapsed = Int(now().timeIntervalSince(startedAt).rounded())
        let won = winner == localPlayer
        // Each player's board is their own private table, so this is this
        // device's own count and nobody else's.
        let tiles = session.state.board.placements.count
        await write {
            let current = try await store.profile(localID)
            try await store.updateProfile(
                localID,
                .after(current, won: won, tilesPlaced: tiles, elapsedSeconds: elapsed)
            )
        }
    }

    private func write(_ body: () async throws -> Void) async {
        do { try await body() } catch { lastError = error }
    }

    // MARK: The observation loop

    /// Observes the session until there is nothing left to record.
    ///
    /// The stream is armed *before* the first ``sync()`` and buffers one
    /// element, so a change that lands while a write is in flight wakes this
    /// rather than being lost between a read and a re-registration.
    public func run() async {
        let (changes, continuation) = AsyncStream<Void>.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        watch(continuation)
        await sync()
        if isDone { continuation.finish(); return }
        for await _ in changes {
            await sync()
            if isDone { break }
        }
        continuation.finish()
    }

    /// Re-arms itself on every change: `withObservationTracking` fires once.
    private func watch(_ continuation: AsyncStream<Void>.Continuation) {
        withObservationTracking {
            _ = session.state.status
            _ = session.peerPresences
        } onChange: {
            continuation.yield()
            Task { @MainActor [weak self] in self?.watch(continuation) }
        }
    }
}
