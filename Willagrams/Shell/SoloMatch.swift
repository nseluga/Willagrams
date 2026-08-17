//
//  SoloMatch.swift
//  Willagrams
//
//  A playable match with one real player. Solo is a *configuration* of the
//  match engine, never a mode inside it: the engine gets the same transport,
//  the same host election and the same pool it gets against a real opponent,
//  and the only difference is that the far end of the wire never speaks.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

// `FakeTransport` is `#if DEBUG` by design — it must not be reachable from a
// shipping build. A solo practice session is built on it, so the whole file
// carries the same fence rather than smuggling the transport past it.
#if DEBUG

// The app compiles `Willagrams/Match` and `Willagrams/Shell` into one module,
// where there is nothing to import. `Tests/ShellTests` compiles them as two, so
// the import is real there and only there.
#if canImport(Match)
import Match
#endif

import Foundation
import WillagramsRules

/// Builds and owns one solo practice session.
///
/// Three things have to be true for the local player to get a whole game out of
/// an engine built for two, and all three are settled here rather than by
/// retrying anything:
///
/// 1. **The local player is host by construction.** `MatchSession.startMatch`
///    silently no-ops for a non-host, so the two ids are handed to the very
///    election the session will run — ``HostPool/host(of:_:)`` — and whichever
///    it names becomes the local end.
/// 2. **The far end is silent.** It consumes its inbound stream and does
///    nothing with it: no words, no draws, no schedule, no difficulty. It exists
///    so the wire has two ends.
/// 3. **The far end still costs tiles.** `HostPool` grants one tile to *each*
///    player per draw event, and the opening deal takes `startingHandSize` per
///    player, so a solo match spends the pool twice as fast as one player
///    consumes it. See ``drawsAvailable(handSize:)`` for what that leaves.
@MainActor
public final class SoloMatch {

    /// The two ids, and the election that decides which of them is ours. Naming
    /// them in an order that happens to elect the local player would be a fact
    /// about string comparison; running the real election is a fact about the
    /// engine.
    private static let candidates = (
        PlayerID(rawValue: "solo-local"),
        PlayerID(rawValue: "solo-remote")
    )
    public static let localPlayerID = HostPool.host(of: candidates.0, candidates.1)
    public static let peerPlayerID =
        localPlayerID == candidates.0 ? candidates.1 : candidates.0

    /// How many rounds the local player can draw after the opening deal.
    ///
    /// One draw event takes `players.count` tiles — two — and hands one of them
    /// to a player who will never use it. The opening deal takes `handSize` per
    /// player for the same reason. So of a 144-tile pool the local player's
    /// share is exactly half, 72 tiles: `handSize` dealt plus this many drawn.
    /// At the shipped `ShellModel.soloHandSize` of 21 that is 51 further rounds
    /// — a full-length game, not one that stops half way, because a solo player
    /// is spending the same half of the pool a real opponent would have left
    /// them.
    public static func drawsAvailable(handSize: Int) -> Int {
        (LetterDistribution.totalTiles - handSize * 2) / 2
    }

    /// The local end. Everything the shell renders reads off this.
    public let session: MatchSession

    /// Every tile the far end was granted.
    ///
    /// Not intelligence and not a rack: nothing reads it back into the match.
    /// It is the only place the tiles burned by the silent end are visible, so a
    /// test can prove no tile reached both ends and that the pool was spent
    /// exactly once.
    public private(set) var peerTileIDs: Set<UUID> = []

    private let setup: MatchSetup
    /// The far end of the wire. Exposed so a test can send from it — the only
    /// way to prove a message from a finished match's transport cannot reach the
    /// session that replaced it. Nothing in the shell sends on it.
    public let peerTransport: FakeTransport
    /// The single consumer of the far end's inbound stream. A second one would
    /// divide the messages between them rather than fail.
    private var peerPump: Task<Void, Never>?

    public init(
        setup: MatchSetup,
        dictionary: any WordList,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.setup = setup
        let (local, peer) = FakeTransport.pair(Self.localPlayerID, Self.peerPlayerID)
        self.peerTransport = peer
        self.session = MatchSession(
            transport: local,
            peerPlayerID: Self.peerPlayerID,
            dictionary: dictionary,
            sleepFor: sleepFor
        )

        // Bound to a `let` exactly once, then iterated once — the same rule the
        // session's own pump follows.
        let inbound = peer.inboundMessages
        peerPump = Task { @MainActor [weak self] in
            for await message in inbound {
                guard let self else { return }
                // The whole of what the far end does with a message.
                if case let .grant(player, tiles) = message, player == Self.peerPlayerID {
                    self.peerTileIDs.formUnion(tiles.map(\.id))
                }
            }
        }
    }

    /// Opens the match. The local player is host, so this never hits the host
    /// rejection in `startMatch` and `session.lastNote` stays nil.
    public func start() {
        session.startMatch(
            seed: setup.seed,
            startingHandSize: setup.startingHandSize,
            countdownSeconds: setup.countdownSeconds
        )
    }

    /// Ends the session and the far end with it.
    public func leave() {
        session.leave()
        peerPump?.cancel()
        peerTransport.leave()
    }

    deinit {
        peerPump?.cancel()
    }
}

#endif
