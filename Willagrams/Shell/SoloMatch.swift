//
//  SoloMatch.swift
//  Willagrams
//
//  A playable match with one real player. Solo is a *configuration* of the
//  match engine, never a mode inside it: the engine gets the same transport,
//  the same host election and the same pool it gets against a real opponent,
//  and the only difference is who sits at the far end.
//
//  That far end is `BotMatch` — a real `MatchSession` on a real
//  `LocalMatchLink`, which ships. It used to be a `FakeTransport` with a silent
//  pump behind it, which is why this file and everything holding it carried an
//  `#if DEBUG` fence. Nothing here is debug-only any more and the fence is gone.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match`, `Willagrams/Bot` and `Willagrams/Shell`
// into one module, where there is nothing to import. `Tests/ShellTests`
// compiles them as separate ones, so the imports are real there and only there.
#if canImport(Match)
import Match
#endif
#if canImport(Bot)
import Bot
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
///    silently no-ops for a non-host, and a bot holding the `HostPool` would
///    mint its own tiles. ``BotMatch`` runs the very election the session will
///    run — ``HostPool/host(of:)`` — and whichever id it names becomes the local
///    end.
/// 2. **The far end is a real session.** It is dealt to, it draws, and it plays
///    the tiles it is given. Nothing about it is simulated at the wire.
/// 3. **The far end still costs tiles.** `HostPool` grants one tile to *each*
///    player per draw event, and the opening deal takes `startingHandSize` per
///    player, so a solo match spends the pool twice as fast as one player
///    consumes it. See ``drawsAvailable(handSize:)`` for what that leaves.
///
/// ## The brain is optional, and off by default
///
/// A `nil` ``difficulty`` builds the far end and never starts a ``BotBrain``
/// over it: the bot is dealt to and stays silent, which is what a test asserting
/// on grants, pool arithmetic or tile conservation needs — a brain playing in
/// the background would move the very counts under it. The app passes a real
/// difficulty, so a player always gets an opponent. There is no third mode here
/// and no flag inside the brain: an opponent that does nothing is simply a match
/// with no brain built.
@MainActor
public final class SoloMatch {

    /// The local player's id, and the far end's. The election lives in
    /// ``BotMatch`` — restating it here is how the two answers start to
    /// disagree — and these are the shell's names for what it decided.
    public static var localPlayerID: PlayerID { BotMatch.humanPlayerID }
    public static var peerPlayerID: PlayerID { BotMatch.botPlayerID }

    /// How many rounds the local player can draw after the opening deal.
    ///
    /// One draw event takes `players.count` tiles — two — and hands one of them
    /// to the far end. The opening deal takes `handSize` per player for the same
    /// reason. So of a 144-tile pool the local player's share is exactly half,
    /// 72 tiles: `handSize` dealt plus this many drawn. At the shipped
    /// `ShellModel.soloHandSize` of 21 that is 51 further rounds — a full-length
    /// game, because a solo player is spending the same half of the pool a real
    /// opponent would have left them.
    public static func drawsAvailable(handSize: Int) -> Int {
        (LetterDistribution.totalTiles - handSize * 2) / 2
    }

    /// The local end. Everything the shell renders reads off this.
    public let session: MatchSession

    /// The far end of the wire, whole: its session, its transport and the
    /// dictionary it was built against.
    public let bot: BotMatch

    /// Every tile the far end holds — in its rack, on its board, and owed to it.
    ///
    /// Computed off the bot's own session rather than counted from the wire, so
    /// there is no shell-side ledger of grants to disagree with the rack it
    /// claims to describe. It is the only place the tiles the far end is
    /// spending are visible, so a test can prove no tile reached both ends and
    /// that the pool was spent exactly once.
    ///
    /// `pendingDrawTiles` counts. A grant the far end did not ask for — the one
    /// it is owed because *this* end drew — parks there until it presses Draw,
    /// and a brainless far end never presses. Those tiles are spent out of the
    /// pool and held by the far end all the same, so leaving them out would make
    /// the two ends fail to account for the pool by exactly the number of rounds
    /// played.
    public var peerTileIDs: Set<UUID> {
        var ids = Set(bot.session.state.hand.map(\.id))
        ids.formUnion(bot.session.pendingDrawTiles.map(\.id))
        ids.formUnion(bot.session.state.board.placementList.map(\.tile.id))
        return ids
    }

    /// The far end's transport. Named for the shell's half of the vocabulary —
    /// `peer` is what `MatchSession` calls whoever is not us — and handed
    /// straight through to ``BotMatch/botTransport``.
    public var peerTransport: LocalMatchLink { bot.botTransport }

    /// How hard the far end plays, or `nil` for a far end that does not play at
    /// all. See "The brain is optional" above.
    public let difficulty: BotDifficulty?

    private let setup: MatchSetup

    /// The brain's own task. Held so ``leave()`` cancels it rather than leaving
    /// it thinking about a match that has ended.
    private var brainTask: Task<Void, Never>?

    public init(
        setup: MatchSetup,
        dictionary: any WordList,
        difficulty: BotDifficulty? = nil,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.setup = setup
        self.difficulty = difficulty
        let bot = BotMatch(dictionary: dictionary, sleepFor: sleepFor)
        self.bot = bot
        self.session = MatchSession(
            transport: bot.humanTransport,
            peerPlayerID: BotMatch.botPlayerID,
            dictionary: dictionary,
            sleepFor: sleepFor
        )
    }

    /// Opens the match, and sets the far end thinking if it has a brain.
    ///
    /// The local player is host, so this never hits the host rejection in
    /// `startMatch` and `session.lastNote` stays nil. The brain is started after
    /// the deal is on the wire, never before: a brain that runs first would take
    /// its first look at an empty rack.
    public func start() {
        session.startMatch(
            seed: setup.seed,
            startingHandSize: setup.startingHandSize,
            countdownSeconds: setup.countdownSeconds,
            // The rules the setup screen chose, carried by the setup itself —
            // so the match is played under what the player picked rather than
            // under whatever `startMatch` assumes when nobody says.
            options: setup.options
        )
        guard let difficulty, brainTask == nil else { return }
        let brain = BotBrain(match: bot, difficulty: difficulty)
        brainTask = Task { @MainActor in await brain.run() }
    }

    /// Ends the session, the brain and the far end with it.
    ///
    /// Every part is idempotent, so tearing a run down twice cannot reach a live
    /// one. The brain is cancelled first: a brain that took a turn between the
    /// two sessions leaving would be playing into a wire with no one on it.
    public func leave() {
        brainTask?.cancel()
        brainTask = nil
        session.leave()
        bot.leave()
    }

    deinit {
        brainTask?.cancel()
    }
}
