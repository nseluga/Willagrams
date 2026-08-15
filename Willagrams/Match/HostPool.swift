//
//  HostPool.swift
//  Willagrams
//
//  Host authority over the pool. One device holds the only real `Pool`; the
//  other asks and is told what it got. No tile enters a rack except through a
//  grant sent from here, so two devices can never disagree about what is left.
//
//  This file must never import GameKit.
//

import WillagramsRules

/// The host's answer service for pool requests.
///
/// An `actor` because the pool is mutable state reached from the inbound
/// message pump on one side and the host's own UI on the other. That isolation
/// is what makes "one tile per player, once" true when two requests land
/// together — the second request sees the pool the first one left.
///
/// It deliberately does not subscribe to `transport.inboundMessages` itself:
/// that stream supports exactly one consumer, and a second one would silently
/// divide messages between the two rather than fail. The session above owns the
/// stream and hands each message to ``handle(_:)``.
public actor HostPool {

    /// Which of two players runs the pool.
    ///
    /// Pure and total, so both devices compute the same answer from the same
    /// two ids with no negotiation message — never a timestamp, a random value
    /// or connection order. Lower `rawValue` wins, so the answer does not
    /// depend on argument order either.
    public static func host(of first: PlayerID, _ second: PlayerID) -> PlayerID {
        first.rawValue <= second.rawValue ? first : second
    }

    /// The one real pool in the match. Readable so the host's own UI can show
    /// how many tiles are left; only this actor may move it.
    public private(set) var pool: Pool

    /// Both players, ordered by `rawValue` so a fan-out does not depend on the
    /// order the caller happened to name them in.
    private let players: [PlayerID]

    private let transport: any MatchTransport

    /// `Pool.swap` needs one, and it has to survive between requests: a fresh
    /// generator per swap would put every returned tile in the same place.
    private var generator: SeededGenerator

    /// - Parameters:
    ///   - pool: the pool this match plays from. Injected rather than built
    ///     from a seed here, so a caller — or a test — can start a match one
    ///     tile away from exhaustion.
    ///   - seed: seeds the generator `Pool.swap` draws from, so a match replays
    ///     the same way.
    public init(
        players: (PlayerID, PlayerID),
        pool: Pool,
        seed: UInt64,
        transport: any MatchTransport
    ) {
        self.players = [players.0, players.1].sorted { $0.rawValue < $1.rawValue }
        self.pool = pool
        self.generator = SeededGenerator(seed: seed)
        self.transport = transport
    }

    /// Answers one request from either player.
    ///
    /// Anything that is not a pool request is ignored — this type owns the
    /// pool, not the match.
    ///
    /// - Returns: the messages that went on the wire, in send order. The host
    ///   device does not receive its own sends, so this is how it learns about
    ///   the grant addressed to itself. Empty when the message was not a
    ///   request.
    @discardableResult
    public func handle(_ message: MatchMessage) async -> [MatchMessage] {
        switch message {

        case let .drawRequest(player):
            // A request naming somebody who is not in this match must not be
            // able to move the pool: the payload arrived from a peer.
            guard players.contains(player) else {
                return await send([.rejected(reason: .unknownPlayer)])
            }
            // One draw for the whole fan-out. It takes a tile for every player
            // or none at all, so a pool too small to go round is refused with
            // the pool untouched rather than half dealt.
            guard let drawn = pool.draw(players.count) else {
                return await send([.poolExhausted])
            }
            return await send(
                zip(players, drawn).map { player, tile in
                    MatchMessage.grant(player: player, tiles: [tile])
                }
            )

        case let .swapRequest(player, returning):
            guard players.contains(player) else {
                return await send([.rejected(reason: .unknownPlayer)])
            }
            // `Pool.swap` returns nil and leaves the pool untouched when fewer
            // than three remain, which is the whole of the rollback story.
            guard let drawn = pool.swap(returning, using: &generator) else {
                return await send([.rejected(reason: .notEnoughTilesToSwap)])
            }
            return await send([.swapGrant(player: player, tiles: drawn, returned: returning)])

        default:
            return []
        }
    }

    /// Puts `messages` on the wire in order and hands them back.
    ///
    /// A failed send is swallowed: the only failure a transport reports is a
    /// peer that has already gone, the connection-state stream reports that
    /// authoritatively, and by here the pool has already moved. Retrying into a
    /// dead peer would be the one way to hand the same tile out twice.
    private func send(_ messages: [MatchMessage]) async -> [MatchMessage] {
        for message in messages {
            try? await transport.send(message, delivery: .reliable)
        }
        return messages
    }
}
