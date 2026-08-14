import Foundation

/// Where a match is in its lifecycle.
///
/// There is no dealing phase to name — the countdown runs, tiles arrive, play
/// starts.
public enum MatchStatus: Codable, Sendable, Equatable {
    case countdown(secondsRemaining: Int)
    case playing
    case finished(winner: PlayerID)
}

/// One player's whole view of a match: their private board, their unplaced
/// tiles, and what they know of the pool.
///
/// A local practice game uses the same type with no peers attached, which is
/// why nothing here mentions GameKit.
public struct GameState: Codable, Sendable, Equatable {
    public var pool: Pool
    /// Tiles drawn but not yet placed — the rack.
    public var hand: [Tile]
    public var board: Board
    public var status: MatchStatus

    public init(pool: Pool, hand: [Tile] = [], board: Board = Board(), status: MatchStatus = .playing) {
        self.pool = pool
        self.hand = hand
        self.board = board
        self.status = status
    }

    /// Whether this player may Draw: every tile placed, one cluster, all words real.
    ///
    /// The board being complete is not enough — a tile still sitting in hand
    /// means you have not used everything.
    public func canDraw(against dictionary: some WordList) -> Bool {
        hand.isEmpty && board.validate(against: dictionary).isComplete
    }

    /// Moves a tile from the hand onto the board.
    /// - Throws: `PlacementError.tileNotInHand` or `PlacementError.occupied`.
    public mutating func place(tileID: UUID, at coord: Coord) throws {
        guard let index = hand.firstIndex(where: { $0.id == tileID }) else {
            throw PlacementError.tileNotInHand(tileID)
        }
        try board.place(hand[index], at: coord)
        hand.remove(at: index)
    }

    /// Returns a placed tile to the hand. No-op if the cell is empty.
    public mutating func recall(from coord: Coord) {
        guard let tile = board.remove(at: coord) else { return }
        hand.append(tile)
    }
}
