import Foundation
import Testing
import WillagramsRules
import Match
@testable import Bot

/// Rung 3 — giving a tile back — driven through a real `MatchSession` on a real
/// link, with the bot's own outgoing wire counted.
///
/// The counting is the point. Every criterion here is "how many `swapRequest`
/// messages left the bot", which no amount of rack- or note-watching answers:
/// a brain that asked twice and was refused twice looks, from the session's
/// state, exactly like a brain that asked once.
@MainActor
@Suite("Bot swap")
struct BotSwapTests {

    // MARK: - Instruments

    /// The bot's transport, wrapped: counts `swapRequest` on its way out and,
    /// optionally, answers it from here instead of letting the host see it.
    ///
    /// Not a `MatchSession` double — the session below is the real one, and so
    /// is the link underneath. This only sits in the middle of the wire.
    final class SwapTap: MatchTransport, @unchecked Sendable {
        private let base: LocalMatchLink
        private let lock = NSLock()
        private var count = 0
        /// Sent straight back to the bot in place of forwarding the request.
        /// `nil` forwards, and the real host answers.
        private let answer: MatchMessage?
        /// How long the answer is held back. A refusal that comes back
        /// instantly leaves no window for a second request to be sent in.
        private let delay: Duration
        private let inbound: AsyncStream<MatchMessage>.Continuation

        let inboundMessages: AsyncStream<MatchMessage>
        /// Set the instant a `swapGrant` reaches the bot's end of the wire.
        let grantLanded = UncheckedFlag()

        var swapRequests: Int { lock.withLock { count } }
        private func noteRequest() { lock.withLock { count += 1 } }

        init(
            _ base: LocalMatchLink,
            answering answer: MatchMessage? = nil,
            after delay: Duration = .zero
        ) {
            self.base = base
            self.answer = answer
            self.delay = delay
            let stream = AsyncStream.makeStream(
                of: MatchMessage.self, bufferingPolicy: .unbounded
            )
            self.inboundMessages = stream.stream
            self.inbound = stream.continuation
            let landed = grantLanded
            let continuation = stream.continuation
            Task {
                for await message in base.inboundMessages {
                    if case .swapGrant = message { landed.set() }
                    continuation.yield(message)
                }
                continuation.finish()
            }
        }

        var localPlayerID: PlayerID { base.localPlayerID }
        var peerConnectionStates: AsyncStream<PeerConnectionState> { base.peerConnectionStates }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
            if case .swapRequest = message {
                noteRequest()
                if let answer {
                    let inbound = inbound
                    let delay = delay
                    Task {
                        try? await Task.sleep(for: delay)
                        inbound.yield(answer)
                    }
                    return
                }
            }
            try await base.send(message, delivery: delivery)
        }

        func leave() {
            inbound.finish()
            base.leave()
        }
    }

    /// Nothing is a word until `thawed` is set, and then everything is.
    ///
    /// Frozen, the bot can place exactly one tile and then legitimately has no
    /// move at any rung — which is the state rung 3 exists for. Thawed, every
    /// run of tiles is legal again, so the very next tick has a placement.
    struct ThawingWordList: WordList {
        let thawed: UncheckedFlag
        func contains(_ word: String) -> Bool { thawed.isSet }
    }

    /// A real bot session on a tapped wire, and the real human host beside it.
    static func linked(
        _ dictionary: some WordList,
        answering answer: MatchMessage? = nil,
        after delay: Duration = .zero
    ) -> (bot: MatchSession, human: MatchSession, tap: SwapTap) {
        let (humanLink, botLink) = LocalMatchLink.pair(
            BotMatch.humanPlayerID, BotMatch.botPlayerID
        )
        let tap = SwapTap(botLink, answering: answer, after: delay)
        let bot = MatchSession(
            transport: tap,
            peerPlayerID: BotMatch.humanPlayerID,
            dictionary: dictionary,
            sleepFor: { _ in }
        )
        let human = MatchSession(
            transport: humanLink,
            peerPlayerID: BotMatch.botPlayerID,
            dictionary: dictionary,
            sleepFor: { _ in }
        )
        return (bot, human, tap)
    }

    /// Deliberately unreachable stall floor: everything below reaches rung 3
    /// from its declared depth or not at all.
    static func never(_ depth: Int) -> BotDifficulty {
        BotDifficulty(ladderDepth: depth, thinkDelay: .milliseconds(2), stallFloorTicks: 1_000_000)
    }

    /// A stall floor that fires constantly, so the grant it hands out is under
    /// test on every tick.
    static func always(_ depth: Int) -> BotDifficulty {
        BotDifficulty(ladderDepth: depth, thinkDelay: .milliseconds(2), stallFloorTicks: 2)
    }

    // MARK: - Criterion 1 · one request, then a tile goes down

    /// A depth-3 bot on a rack and board that admit no placement. It must ask
    /// once — not twice, and not from the stall floor, which is set out of
    /// reach — and must go back to placing once the grant lands.
    @Test("A depth-3 bot with no move asks to swap exactly once and plays on the grant")
    func swapIsAskedOnceAndUnblocksTheBot() async throws {
        let thawed = UncheckedFlag()
        let list = ThawingWordList(thawed: thawed)
        let (bot, human, tap) = Self.linked(list)
        defer { bot.leave(); human.leave() }
        human.startMatch(seed: 21, startingHandSize: 5, countdownSeconds: 0)
        try await BotBrainTests.waitUntil("bot dealt") { bot.state.hand.count == 5 }

        let brain = BotBrain(session: bot, dictionary: list, difficulty: Self.never(3))
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        // One tile is legal on its own; a second would spell a non-word. So the
        // bot lands one and then has nothing at any searching rung.
        try await BotBrainTests.waitUntil("the one legal tile landed") {
            bot.state.board.placements.count == 1
        }
        // Rung 3, on the wire.
        try await BotBrainTests.waitUntil("the swap request went out") {
            tap.swapRequests >= 1
        }
        // One back, three out: the grant is the only thing that can move the
        // rack from four tiles to six.
        try await BotBrainTests.waitUntil("the swap grant landed") {
            tap.grantLanded.isSet && bot.state.hand.count == 6
        }
        thawed.set()

        try await BotBrainTests.waitUntil("the bot placed again after the grant") {
            bot.state.board.placements.count > 1
        }
        driver.cancel()
        #expect(tap.swapRequests == 1, "\(tap.swapRequests) swap requests, not one")
        // The brain counted no draw for it: the swap cost tiles, not credits,
        // and the session is the one that says so.
        #expect(bot.hasPendingDraw == false)
    }

    // MARK: - Criterion 2 · a refusal stands for the match

    /// Both refusals the session decodes, injected onto the bot's own wire so
    /// the decode path is the real one. Either way the answer stands: over
    /// hundreds of ticks, with the stall floor firing throughout, exactly one
    /// request was ever sent.
    ///
    /// The answer is held back for 150 ms on purpose. That window — ~75 ticks,
    /// ~35 stall-floor grants — is where a brain that only re-read the rack and
    /// `canDraw` would fire a fresh request every other tick, long before there
    /// is any refusal to latch on.
    @Test(
        "A refused swap is never asked again",
        arguments: [RejectionReason.swapDisabled, RejectionReason.notEnoughTilesToSwap]
    )
    func aRefusedSwapIsNeverRetried(_ reason: RejectionReason) async throws {
        let list = BotBrainTests.NoWordList()
        let (bot, human, tap) = Self.linked(
            list, answering: .rejected(reason: reason), after: .milliseconds(150)
        )
        defer { bot.leave(); human.leave() }
        human.startMatch(seed: 21, startingHandSize: 5, countdownSeconds: 0)
        try await BotBrainTests.waitUntil("bot dealt") { bot.state.hand.count == 5 }

        let brain = BotBrain(session: bot, dictionary: list, difficulty: Self.always(3))
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        try await BotBrainTests.waitUntil("the swap request went out") {
            tap.swapRequests >= 1
        }
        try await BotBrainTests.waitUntil("the refusal was decoded") {
            bot.lastNote?.hasPrefix("refused:") == true
        }
        // Long enough for ~300 ticks at 2 ms, and the stall floor fires every
        // second one of them.
        try await Task.sleep(for: .milliseconds(600))
        driver.cancel()

        #expect(tap.swapRequests == 1, "\(tap.swapRequests) swap requests after a refusal")
        // Still stuck, still silent, and no tile went missing over the wait.
        #expect(bot.state.board.placements.count == 1)
        #expect(bot.state.hand.count == 4)
    }

    /// The other face of `.swapDisabled`: the host opened the match with
    /// swapping off, so the bot's own session says no before anything reaches
    /// the wire. Nothing is asked at all, and nothing is asked later either.
    @Test("A match with swapping off gets no swap request at all")
    func swappingOffIsNeverAsked() async throws {
        var options = MatchOptions.standard
        options.swapEnabled = false
        let list = BotBrainTests.NoWordList()
        let (bot, human, tap) = Self.linked(list)
        defer { bot.leave(); human.leave() }
        human.startMatch(seed: 21, startingHandSize: 5, countdownSeconds: 0, options: options)
        try await BotBrainTests.waitUntil("bot dealt") { bot.state.hand.count == 5 }
        #expect(bot.options.swapEnabled == false)

        let brain = BotBrain(session: bot, dictionary: list, difficulty: Self.always(3))
        let driver = Task { await brain.run() }
        defer { driver.cancel() }
        try await BotBrainTests.waitUntil("the one legal tile landed") {
            bot.state.board.placements.count == 1
        }
        try await Task.sleep(for: .milliseconds(400))
        driver.cancel()

        #expect(tap.swapRequests == 0)
    }

    // MARK: - Criterion 3 · rung 3 is out of a depth-2 bot's reach

    /// The clamp. Same unplayable rack, same board, same relentless stall floor
    /// — only the declared depth differs, and the floor's one-rung grant must
    /// not carry a depth-2 bot onto a rung that speaks to the host.
    @Test(
        "A bot at ladderDepth 2 or below never asks to swap, stall floor or not",
        arguments: [0, 1, 2]
    )
    func belowDepthThreeNeverSwaps(_ depth: Int) async throws {
        let list = BotBrainTests.NoWordList()
        let (bot, human, tap) = Self.linked(
            list, answering: .rejected(reason: .notEnoughTilesToSwap)
        )
        defer { bot.leave(); human.leave() }
        human.startMatch(seed: 21, startingHandSize: 5, countdownSeconds: 0)
        try await BotBrainTests.waitUntil("bot dealt") { bot.state.hand.count == 5 }

        let brain = BotBrain(session: bot, dictionary: list, difficulty: Self.always(depth))
        let driver = Task { await brain.run() }
        defer { driver.cancel() }
        try await BotBrainTests.waitUntil("the one legal tile landed") {
            bot.state.board.placements.count == 1
        }
        // Many stall-floor windows: at 2 ms a tick and a floor of 2, the grant
        // fires ~100 times in here.
        try await Task.sleep(for: .milliseconds(600))
        driver.cancel()

        #expect(tap.swapRequests == 0, "a depth-\(depth) bot asked to swap")
        #expect(bot.state.hand.count == 4)
    }

    // MARK: - The heuristic

    /// Least useful, and the same answer twice.
    ///
    /// `AT` is the only word, so `A` and `T` are both usable and `Q` and `Z` are
    /// not. Between the two unusable tiles, `Q` is the rarer letter in English.
    @Test("The tile handed back is the rarest one no pair in the rack can use")
    func theLeastUsefulTileIsChosenDeterministically() async throws {
        struct OnlyAT: WordList {
            func contains(_ word: String) -> Bool { word == "AT" }
        }
        let a = Tile(letter: "A"), t = Tile(letter: "T")
        let q = Tile(letter: "Q"), z = Tile(letter: "Z")
        let match = BotMatch(dictionary: OnlyAT(), sleepFor: { _ in })
        defer { match.leave() }
        let brain = BotBrain(
            session: match.session, dictionary: OnlyAT(), difficulty: .hard
        )
        let snapshot = BotBrain.Snapshot(
            hand: [a, t, q, z], board: Board(), options: .standard
        )
        #expect(await brain.giveBack(snapshot)?.id == q.id)
        // Same rack, same tile — twice, and again with the rack shuffled, since
        // "least useful" is a fact about the multiset and not about the order.
        #expect(await brain.giveBack(snapshot)?.id == q.id)
        let shuffled = BotBrain.Snapshot(
            hand: [z, q, t, a], board: Board(), options: .standard
        )
        #expect(await brain.giveBack(shuffled)?.id == q.id)

        // Nothing to give back is nothing, not a crash.
        let empty = BotBrain.Snapshot(hand: [], board: Board(), options: .standard)
        #expect(await brain.giveBack(empty) == nil)
    }

    /// Every letter pairs, so the pair test separates nothing and the frequency
    /// table decides: `Z` is rarer than `E`, `A` and `T`.
    @Test("With every letter usable the rarest letter is still the one given back")
    func frequencyBreaksTheTieWhenEveryLetterPairs() async throws {
        struct Everything: WordList {
            func contains(_ word: String) -> Bool { true }
        }
        let match = BotMatch(dictionary: Everything(), sleepFor: { _ in })
        defer { match.leave() }
        let brain = BotBrain(
            session: match.session, dictionary: Everything(), difficulty: .hard
        )
        let z = Tile(letter: "Z")
        let snapshot = BotBrain.Snapshot(
            hand: [Tile(letter: "E"), Tile(letter: "A"), z, Tile(letter: "T")],
            board: Board(),
            options: .standard
        )
        #expect(await brain.giveBack(snapshot)?.id == z.id)
        #expect(BotBrain.frequency("Z") < BotBrain.frequency("E"))
    }
}
