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
    /// `0` extend · `1` repair · `2` rebuild · `3` swap. Rung 0 is the whole
    /// ladder today; rungs 1–3 arrive in later items and are a no-op until
    /// then, so a preset naming a depth above 0 plays exactly like depth 0
    /// rather than misbehaving.
    public var ladderDepth: Int

    /// The pause between placements. The bot is not slow — it is *paced*, so a
    /// human can watch tiles land instead of a board appearing at once.
    ///
    /// Also the tick interval when the brain finds nothing to do. A test drives
    /// the brain with `.zero` here; nothing else in the lane sleeps.
    public var thinkDelay: Duration

    /// How many consecutive ticks the brain may find no move before the stall
    /// floor fires — the point at which a rung-2 rebuild becomes worth its cost
    /// rather than the brain sitting on an unplayable rack forever.
    ///
    /// Consumed by item 4. Named here because it is a tuning constant and this
    /// is where tuning constants live.
    public var stallFloorTicks: Int

    public init(ladderDepth: Int, thinkDelay: Duration, stallFloorTicks: Int) {
        self.ladderDepth = ladderDepth
        self.thinkDelay = thinkDelay
        self.stallFloorTicks = stallFloorTicks
    }

    /// Extend only, slowly, and patient about being stuck.
    public static let easy = BotDifficulty(
        ladderDepth: 0,
        thinkDelay: .milliseconds(1200),
        stallFloorTicks: 12
    )

    /// Extend, repair and rebuild, at a conversational pace.
    public static let medium = BotDifficulty(
        ladderDepth: 2,
        thinkDelay: .milliseconds(600),
        stallFloorTicks: 6
    )

    /// The whole ladder, swap included, and quick to give up on a bad rack.
    public static let hard = BotDifficulty(
        ladderDepth: 3,
        thinkDelay: .milliseconds(250),
        stallFloorTicks: 3
    )
}
