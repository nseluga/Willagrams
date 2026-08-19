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
/// The isolation covers the pool and nothing else. ``handle(_:)`` suspends
/// while it sends, so two callers running at once still interleave what reaches
/// the wire — see the precondition there.
///
/// It deliberately does not subscribe to `transport.inboundMessages` itself:
/// that stream supports exactly one consumer, and a second one would silently
/// divide messages between the two rather than fail. The session above owns the
/// stream and hands each message to ``handle(_:)``.
public actor HostPool {

    /// Which player in a roster runs the pool.
    ///
    /// Pure and total, so every device computes the same answer from the same
    /// roster with no negotiation message — never a timestamp, a random value
    /// or connection order. Lowest `rawValue` wins, so the answer does not
    /// depend on the order the caller happened to name them in, and it agrees
    /// with `ValidatedStart.host`, which reads `roster[0]` off a sorted roster.
    ///
    /// - Precondition: `players` is not empty.
    public static func host(of players: [PlayerID]) -> PlayerID {
        precondition(!players.isEmpty, "a match needs at least one player")
        return players.min { $0.rawValue < $1.rawValue }!
    }

    /// The one real pool in the match. Readable so the host's own UI can show
    /// how many tiles are left; only this actor may move it.
    public private(set) var pool: Pool

    /// Every player in the match, ordered by `rawValue` so a fan-out does not
    /// depend on the order the caller happened to name them in.
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
    /// Whether this match allows swapping. Fixed for the life of the match: it
    /// comes from the host's `MatchOptions` on `.start`.
    private let swapEnabled: Bool

    public init(
        players: [PlayerID],
        pool: Pool,
        seed: UInt64,
        transport: any MatchTransport,
        swapEnabled: Bool = true
    ) {
        self.swapEnabled = swapEnabled
        // Our own bug, not a peer payload — a roster off the wire has already
        // been through `MatchMessage.validatedStart` by the time it reaches
        // here. A repeated id would pass the membership guard and fan a round
        // out to the same player twice.
        precondition(
            MatchLimits.players.contains(players.count),
            "a match holds \(MatchLimits.players.lowerBound) to \(MatchLimits.players.upperBound) players, got \(players.count)"
        )
        precondition(Set(players).count == players.count, "a match needs distinct players")
        self.players = players.sorted { $0.rawValue < $1.rawValue }
        self.pool = pool
        self.generator = SeededGenerator(seed: seed)
        self.transport = transport
    }

    /// Answers one request from either player.
    ///
    /// Anything that is not a pool request is ignored — this type owns the
    /// pool, not the match.
    ///
    /// - Precondition: called from one place at a time. The pool is safe either
    ///   way, but this method suspends while it sends, so two concurrent
    ///   callers can interleave on the wire and a later request's
    ///   `poolExhausted` can overtake an earlier grant. The session's inbound
    ///   pump is that single caller, which is why there is no queue here.
    ///
    /// - Returns: the messages this request *produced* — every authoritative
    ///   movement of the pool, in order, whether or not it went on the wire.
    ///   Two kinds never do: the grant addressed to the host, which the host
    ///   applies from this return value because it does not receive its own
    ///   sends, and a refusal of the host's own request, which carries no
    ///   player and would read on the peer as a refusal of its own. A message
    ///   here is not proof of delivery — nothing in this type retries a failed
    ///   send or reports one. Empty when the message was not a request.
    @discardableResult
    public func handle(_ message: MatchMessage) async -> [MatchMessage] {
        switch message {

        case let .drawRequest(player):
            // A request naming somebody who is not in this match must not be
            // able to move the pool: the payload arrived from a peer.
            guard players.contains(player) else {
                return await answer([.rejected(reason: .unknownPlayer)], to: player)
            }
            // One draw for the whole fan-out. It takes a tile for every player
            // or none at all, so a pool too small to go round is refused with
            // the pool untouched rather than half dealt.
            guard let drawn = pool.draw(players.count) else {
                return await answer([.poolExhausted], to: player)
            }
            return await answer(
                zip(players, drawn).map { player, tile in
                    MatchMessage.grant(player: player, tiles: [tile])
                },
                to: player
            )

        case let .swapRequest(player, returning):
            guard players.contains(player) else {
                return await answer([.rejected(reason: .unknownPlayer)], to: player)
            }
            // The host is the only authority on this. A guest that hides its
            // swap control still has a reachable `MatchSession.swap`, and a
            // modified build has one regardless — so the rule is enforced here,
            // with the pool untouched, rather than in anyone's UI.
            guard swapEnabled else {
                return await answer([.rejected(reason: .swapDisabled)], to: player)
            }
            // `returning` came off the wire and goes into the pool unchecked: a
            // modified peer can mint a tile it never held or return the same one
            // twice. Not fixable from here — verifying it needs the rack state
            // the session will own, and this is a hard precondition on that item.
            //
            // `Pool.swap` returns nil and leaves the pool untouched when fewer
            // than three remain, which is the whole of the rollback story.
            guard let drawn = pool.swap(returning, using: &generator) else {
                return await answer([.rejected(reason: .notEnoughTilesToSwap)], to: player)
            }
            return await answer(
                [.swapGrant(player: player, tiles: drawn, returned: returning)],
                to: player
            )

        default:
            return []
        }
    }

    /// Deals the opening hand: `handSize` tiles to every player, once.
    ///
    /// One draw for the whole deal, like a round, so a pool too small to go
    /// round moves nothing rather than dealing one player short. A slice per
    /// player means no tile can reach two racks.
    ///
    /// With six players this is the tight case: `handSize * players.count` has
    /// to fit inside the pool, and `Pool.draw` refusing as a unit is what keeps
    /// the last player from starting a tile short. `validatedStart` refuses the
    /// same arithmetic up front, so a legal match never reaches the refusal
    /// here — this is the second line, not the first.
    ///
    /// - Returns: the grants it produced, the peer's already on the wire and the
    ///   host's for the caller to apply — the same contract as ``handle(_:)``.
    ///   Empty when there is nothing to deal, or not enough pool to deal from:
    ///   no `poolExhausted` goes out, because a match that cannot deal an
    ///   opening hand is a lobby problem, not a mid-match one.
    @discardableResult
    public func deal(handSize: Int) async -> [MatchMessage] {
        guard handSize > 0, let drawn = pool.draw(handSize * players.count) else { return [] }
        let grants = players.enumerated().map { index, player in
            MatchMessage.grant(
                player: player,
                tiles: Array(drawn[(index * handSize)..<((index + 1) * handSize)])
            )
        }
        // No requester: the deal answers nobody's request. Only `rejected` and
        // the default arm read it, and this produces neither.
        return await answer(grants, to: transport.localPlayerID)
    }

    /// Puts the part of `produced` the peer is entitled to see on the wire, in
    /// order, and hands all of `produced` back.
    ///
    /// A failed send is swallowed: the only failure a transport reports is a
    /// peer that has already gone, the connection-state stream reports that
    /// authoritatively, and by here the pool has already moved. Retrying into a
    /// dead peer would be the one way to hand the same tile out twice.
    private func answer(_ produced: [MatchMessage], to requester: PlayerID) async -> [MatchMessage] {
        for message in produced where isForPeer(message, requestedBy: requester) {
            try? await transport.send(message, delivery: .reliable)
        }
        return produced
    }

    /// Whether the peer is entitled to `message`.
    ///
    /// The peer is told what it was given and when the pool runs out. It is not
    /// told which tiles the host holds: a modified client reading the
    /// opponent's rack off the wire would be unbeatable, and nothing on this
    /// side of the wire can stop it reading what we chose to send.
    private func isForPeer(_ message: MatchMessage, requestedBy requester: PlayerID) -> Bool {
        switch message {
        case let .grant(player, _), let .swapGrant(player, _, _):
            return player != transport.localPlayerID
        case .poolExhausted:
            // The one real broadcast: it ends the match for both players.
            return true
        default:
            // `rejected` carries no player, so who asked is the only thing that
            // can route it. The host's own refusal would read as the peer's.
            return requester != transport.localPlayerID
        }
    }
}
