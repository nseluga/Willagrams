//
//  BotMatch.swift
//  Willagrams
//
//  The bot's end of the wire. A real `MatchSession` on a real transport, on the
//  far side of a `LocalMatchLink` from the human — the same engine, the same
//  host election, the same grants. The only thing missing is a brain, which is
//  a later item.
//
//  Modelled on `Willagrams/Shell/SoloMatch.swift`, with one difference that is
//  the whole point of this lane: no `#if DEBUG` fence. This ships.
//
//  NO SwiftUI here — this file is pure state and must stay out of the `Bot`
//  target's `exclude:` list so it compiles into the macOS test target.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match` and `Willagrams/Bot` into one module,
// where there is nothing to import. `Tests/BotTests` compiles them as two, so
// the import is real there and only there.
#if canImport(Match)
import Match
#endif

import WillagramsRules

/// Builds and owns the bot's half of a solo match.
///
/// The caller keeps the human half: ``humanTransport`` is handed straight to a
/// `MatchSession` the caller builds and drives, so nothing about the human's
/// session lives here and there is no back-reference between the two halves.
///
/// Two invariants are settled by construction rather than by checking:
///
/// 1. **The human is host.** A bot holding the `HostPool` would mint its own
///    tiles. The two ids are handed to the very election the session runs —
///    ``HostPool/host(of:)`` — and whichever it names becomes the human. That
///    is a fact about the engine; naming them in an order that happens to elect
///    the human would only be a fact about string comparison.
/// 2. **One consumer per stream.** `MatchSession` already iterates its own
///    inbound and connection-state streams, and the transport permits exactly
///    one consumer of each, so this type adds no pump. A bot that reads the
///    wire would be dividing the stream with its own session.
@MainActor
public final class BotMatch {

    /// The two ids, and the election that decides which of them is the human's.
    ///
    /// Deliberately neutral: whichever id the election names becomes the human,
    /// so a name that asserted which one that was would be a lie half the time.
    private static let candidates = (
        PlayerID(rawValue: "solo-1"),
        PlayerID(rawValue: "solo-2")
    )
    public static let humanPlayerID = HostPool.host(of: [candidates.0, candidates.1])
    public static let botPlayerID =
        humanPlayerID == candidates.0 ? candidates.1 : candidates.0

    /// The human's end of the link. The caller builds their `MatchSession` on
    /// this, with ``botPlayerID`` as the peer.
    public let humanTransport: LocalMatchLink

    /// The bot's end of the same link, the one ``session`` was built on.
    ///
    /// Exposed so a caller can send *as the bot* without a second link: a test
    /// proving what the human's session does with a `.win` or a `.resign` has to
    /// put one on the wire, and minting a fresh pair to do it would be testing a
    /// transport this match never used. Nothing here consumes it — the session
    /// already iterates both of its streams, and the transport permits exactly
    /// one consumer of each.
    public let botTransport: LocalMatchLink

    /// The bot's session. Dealt to and driven by the human's start, and — until
    /// the next item — silent.
    public let session: MatchSession

    /// The list the session was built with, kept so ``BotBrain`` can take its
    /// session and its dictionary from the same place and cannot be handed two
    /// that disagree. Not the *effective* list — the session narrows its own by
    /// the match's minimum word length, and so does the brain, from `options`.
    public let dictionary: any WordList

    public init(
        dictionary: any WordList,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        let (human, bot) = LocalMatchLink.pair(Self.humanPlayerID, Self.botPlayerID)
        self.humanTransport = human
        self.botTransport = bot
        self.dictionary = dictionary
        self.session = MatchSession(
            transport: bot,
            peerPlayerID: Self.humanPlayerID,
            dictionary: dictionary,
            sleepFor: sleepFor
        )
    }

    /// Ends the bot's session and then the link.
    ///
    /// `MatchSession.leave()` already leaves the bot's endpoint, which finishes
    /// every stream on both ends; leaving the human's endpoint after it is what
    /// makes this true no matter which side went first. Both are idempotent, so
    /// so is this — no "left" flag to go stale.
    public func leave() {
        session.leave()
        humanTransport.leave()
    }
}
