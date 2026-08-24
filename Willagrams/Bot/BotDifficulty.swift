//
//  BotDifficulty.swift
//  Willagrams
//
//  Every number that makes the bot easy or hard, in one place with a name.
//  The pre-launch tuning pass edits this file and nothing else — a constant
//  that lives inside `BotBrain` is a constant nobody finds.
//
//  This file must never import GameKit.
//

import Foundation

/// How hard the bot plays.
///
/// Three knobs, deliberately: how far down the move ladder the brain is allowed
/// to reach, how long it pretends to think, and how long it tolerates being
/// stuck before it reaches for the expensive rungs.
public struct BotDifficulty: Sendable, Equatable {

    /// The deepest ladder rung this bot may attempt.
    ///
    /// `0` extend · `1` repair · `2` rebuild · `3` swap. All four exist. Rung
    /// 3 is the only one that speaks to the host rather than moving tiles, and
    /// it is the only rung this number is not the last word on: a bot below
    /// depth 3 never *searches* for a swap, but ``stallFloorTicks`` will hand a
    /// tile back on its behalf once it is demonstrably stuck.
    ///
    /// Rungs 1 and 2 are also where the bot may lay a whole word at once
    /// rather than one tile at a time, which is what makes a tile with no
    /// two-letter word — a `Q`, with no `QI` in the list — placeable at all.
    /// A depth-0 bot cannot do that and will sit on such a tile until the
    /// floor swaps it away.
    public var ladderDepth: Int

    /// The pause between placements, before pacing stretches or squeezes it.
    /// The bot is not slow — it is *paced*, so a human can watch tiles land
    /// instead of a board appearing at once.
    ///
    /// Read it as the *middle* of the bot's rhythm rather than its speed: the
    /// brain multiplies this by a factor drawn from ``pacing`` on every tick,
    /// so what a player actually sees swings either side of it.
    ///
    /// Also the tick interval when the brain finds nothing to do. A test drives
    /// the brain with `.zero` here; nothing else in the lane sleeps. Zero times
    /// any factor is still zero, so pacing costs a test nothing.
    public var thinkDelay: Duration

    /// How far either side of ``thinkDelay`` a single pause may land.
    ///
    /// A bot that pauses the same number of milliseconds every time reads as a
    /// metronome, and a metronome reads as a machine no matter how well it
    /// plays. The brain widens the gap when a tick found nothing and narrows it
    /// while tiles are going down, so the variation is *earned* — the player is
    /// watching an opponent get stuck and then get going again, not watching a
    /// random number. This range is only the clamp on how far that can go.
    public var pacing: ClosedRange<Double>

    /// How many consecutive ticks the brain may place nothing before the stall
    /// floor fires — granting it one attempt at one rung above ``ladderDepth``,
    /// clamped to rung 2, after which the count resets. Once enough of those
    /// grants have come back with nothing changed, the floor takes its own
    /// separate door to rung 3 and hands a tile back. That is an escape, never
    /// a promotion: the bot gains the swap and none of the searching rungs
    /// above its own, so being stuck never makes it a better player.
    ///
    /// This is the floor under every difficulty: an easy bot is allowed to be
    /// bad, not to sit on an unplayable rack for the rest of the match, which
    /// from the player's side of the screen looks exactly like a broken bot.
    public var stallFloorTicks: Int

    public init(
        ladderDepth: Int,
        thinkDelay: Duration,
        stallFloorTicks: Int,
        pacing: ClosedRange<Double> = 0.45...4.0
    ) {
        self.ladderDepth = ladderDepth
        self.thinkDelay = thinkDelay
        self.stallFloorTicks = stallFloorTicks
        self.pacing = pacing
    }

    /// Extend only, slowly, and patient about being stuck.
    public static let easy = BotDifficulty(
        ladderDepth: 0,
        thinkDelay: .milliseconds(1200),
        stallFloorTicks: 12
    )

    /// Extend, repair and rebuild — so it rearranges the board and lays whole
    /// words — at a conversational pace.
    public static let medium = BotDifficulty(
        ladderDepth: 2,
        thinkDelay: .milliseconds(1100),
        stallFloorTicks: 6
    )

    /// The whole ladder, swap included, and quick to give up on a bad rack.
    /// The only preset that hands a tile back *by choice*; the others reach it
    /// only through the stall floor, and only once nothing else is left.
    /// Quick, but never instant: at 250ms every tile landed the moment the one
    /// before it did, which read as a script running rather than a person
    /// playing. The ladder is what makes this bot hard; the clock only made it
    /// inhuman.
    public static let hard = BotDifficulty(
        ladderDepth: 3,
        thinkDelay: .milliseconds(900),
        stallFloorTicks: 3
    )
}
