import BoardKit
import CoreGraphics
import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell
@testable import Style

/// One test per acceptance criterion for the in-match HUD, each driving the
/// real session through the model's own actions — no control is reached past,
/// and nothing here asserts on a board the session did not produce.
@MainActor
@Suite("Match HUD")
struct MatchHUDTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    static let setup = MatchBoardTests.setup

    /// A started solo match, its board wired, a shell sitting on `.match`, and
    /// the HUD over all three.
    static func hud() async throws -> (SoloMatch, MatchBoard, ShellModel, MatchHUDModel) {
        let (solo, wiring) = try await MatchBoardTests.wired()
        let shell = ShellModel(route: .match(setup))
        return (solo, wiring, shell, MatchHUDModel(shell: shell, session: solo.session, board: wiring))
    }

    /// Selects one tile the way a sweep does — through `BoardModel`'s own
    /// painting path, at the point the tile is DRAWN, offset and all.
    static func select(_ placement: Placement, on wiring: MatchBoard) {
        let corner = wiring.camera.point(for: placement.coord)
        let offset = wiring.model.tileOffsets[placement.tile.id] ?? .zero
        let point = CGPoint(
            x: corner.x + wiring.camera.cellSize / 2 + offset.width,
            y: corner.y + wiring.camera.cellSize / 2 + offset.height
        )
        wiring.model.enterSelection()
        wiring.model.painting(from: point, to: point, on: wiring.board, camera: wiring.camera)
    }

    // MARK: - Criterion 1

    /// The HUD shows the host's real remaining count, and it tracks the pool
    /// rather than a snapshot taken once at match start.
    @Test("The pool count is the real one and falls as tiles are drawn")
    func poolCountIsRealAndFalls() async throws {
        let (solo, _, _, hud) = try await Self.hud()

        #expect(hud.poolLabel == Terminology.pool)
        // The opening deal took one hand per player out of a full pool.
        let afterDeal = try #require(hud.poolRemaining)
        #expect(afterDeal == LetterDistribution.totalTiles - Self.setup.startingHandSize * 2)
        #expect(hud.poolValue == String(afterDeal))

        // A draw event costs one tile per player, and the HUD follows it down.
        #expect(solo.session.draw())
        try await SoloMatchTests.waitUntil("the drawn tile") {
            solo.session.state.board.placementList.count == Self.setup.startingHandSize + 1
        }
        try await SoloMatchTests.waitUntil("the count to fall") {
            hud.poolRemaining == afterDeal - 2
        }
        #expect(hud.poolValue == String(afterDeal - 2))

        solo.leave()
    }

    /// A device that runs no pool cannot know the number, and says so rather
    /// than guessing one.
    @Test("A session with no pool of its own shows the placeholder")
    func poolCountIsAbsentWithoutAPool() async throws {
        // Before the match opens there is no pool anywhere yet.
        let solo = SoloMatch(setup: Self.setup, dictionary: EveryWordIsReal(), sleepFor: { _ in })
        #expect(solo.session.poolRemaining == nil)
        solo.leave()

        // And a guest never has one at all.
        let (_, session) = try await MatchBoardTests.guest(
            handSize: 3, dictionary: EveryWordIsReal()
        )
        let shell = ShellModel(route: .match(Self.setup))
        let board = MatchBoard(session: session, dictionary: EveryWordIsReal())
        let hud = MatchHUDModel(shell: shell, session: session, board: board)
        #expect(hud.poolRemaining == nil)
        #expect(hud.poolValue == MatchHUDModel.unknownValue)
        session.leave()
    }

    // MARK: - Criterion 2

    @Test("Draw is unavailable while the board is invalid and available the moment it is valid")
    func drawFollowsBoardValidity() async throws {
        let dictionary = EnableWordList(words: ["GO"])
        let (host, session) = try await MatchBoardTests.guest(handSize: 2, dictionary: dictionary)
        let wiring = MatchBoard(session: session, dictionary: dictionary)
        wiring.viewport = MatchBoardTests.viewport
        let shell = ShellModel(route: .match(Self.setup))
        let hud = MatchHUDModel(shell: shell, session: session, board: wiring)

        try await MatchBoardTests.grant([Tile(letter: "G"), Tile(letter: "O")], from: host)
        try await SoloMatchTests.waitUntil("the opening on the board") {
            wiring.board.placementList.count == 2
        }

        // Two loose letters: two clusters, not drawable.
        #expect(wiring.canDraw == false)
        // Live, not disabled: the press is how the player asks why, and the
        // refusal is the answer. A disabled control swallows the press and the
        // flash never fires. `isDrawPressable` is the gate the button reads —
        // `isDrawEnabled` folds the board in and is false here on purpose.
        #expect(hud.isDrawPressable)
        #expect(hud.isDrawEnabled == false)
        // Refused, not ignored: the press does nothing and says so.
        let before = MatchBoardTests.custody(wiring, session, "before a refused draw")
        #expect(hud.draw() == false)
        #expect(MatchBoardTests.custody(wiring, session, "after a refused draw") == before)
        #expect(session.state.board.placementList.count == 2)

        // The player makes a word.
        let loose = try #require(wiring.board.placementList.first { $0.tile.letter == "O" })
        let joined = try #require(wiring.board.placementList.first { $0.tile.letter == "G" }).coord
        _ = wiring.board.remove(at: loose.coord)
        try wiring.board.place(loose.tile, at: Coord(row: joined.row, col: joined.col + 1))
        wiring.model.seed(wiring.board, against: dictionary)

        #expect(hud.isDrawEnabled)
        #expect(hud.draw())

        session.leave()
    }

    @Test("Draw stays unavailable once the match is over")
    func drawIsUnavailableAfterTheMatchEnds() async throws {
        let (solo, wiring, _, hud) = try await Self.hud()
        wiring.model.seed(wiring.board, against: EveryWordIsReal())
        solo.session.leave()
        #expect(solo.session.isMatchOver)
        #expect(hud.isDrawEnabled == false)
        #expect(hud.draw() == false)
    }

    // MARK: - Criterion 3

    @Test("Swap returns the selected tile and yields three")
    func swapReturnsATileAndYieldsAReplacement() async throws {
        let (solo, wiring, _, hud) = try await Self.hud()
        let returned = try #require(wiring.board.placementList.first)
        Self.select(returned, on: wiring)
        #expect(hud.swappableTile?.id == returned.tile.id)
        #expect(hud.isSwapEnabled)

        #expect(hud.swap(returned.tile))

        // One out, three in — on the board, because that is where every tile
        // this shell holds ends up.
        try await SoloMatchTests.waitUntil("the replacement tiles") {
            wiring.board.placementList.count == Self.setup.startingHandSize + 2
        }
        #expect(solo.session.state.hand.isEmpty)
        #expect(wiring.board.placementList.allSatisfy { $0.tile.id != returned.tile.id })
        let held = MatchBoardTests.custody(wiring, solo.session, "after a swap")
        #expect(held.count == Self.setup.startingHandSize + 2)
        #expect(held.isDisjoint(with: solo.peerTileIDs))

        solo.leave()
    }

    @Test("Swap is refused, and disturbs nothing, once too few tiles remain")
    func swapIsRefusedWhenTooFewTilesRemain() async throws {
        let (solo, wiring, _, hud) = try await Self.hud()

        // Every draw the local player has, taken through the session's own
        // entry point until the pool says it is spent. The poll is what lets
        // the host's actor answer between presses.
        try await SoloMatchTests.waitUntil("the pool to empty", within: .seconds(60)) {
            if !solo.session.poolIsExhausted { _ = solo.session.draw() }
            return solo.session.poolIsExhausted
        }
        try await SoloMatchTests.waitUntil("every granted tile laid") {
            solo.session.state.hand.isEmpty && !solo.session.hasPendingDraw
        }

        let held = MatchBoardTests.custody(wiring, solo.session, "with the pool spent")
        let candidate = try #require(wiring.board.placementList.first)
        Self.select(candidate, on: wiring)
        #expect(hud.swappableTile?.id == candidate.tile.id)

        #expect(hud.isSwapEnabled == false)
        #expect(hud.swap(candidate.tile) == false)

        // Nothing moved: the tile is still where it was and no tile changed
        // hands. The pool itself is not observable from here.
        #expect(solo.session.state.hand.isEmpty, "a refused swap took a tile out of play")
        #expect(wiring.board.tile(at: candidate.coord)?.id == candidate.tile.id)
        #expect(MatchBoardTests.custody(wiring, solo.session, "after a refused swap") == held)

        solo.leave()
    }

    // MARK: - Criterion 4

    @Test("One tap does not resign")
    func oneTapDoesNotResign() async throws {
        let (solo, _, shell, hud) = try await Self.hud()

        hud.armResign()

        #expect(hud.resignArmed)
        #expect(solo.session.isMatchOver == false)
        #expect(shell.route == .match(Self.setup))

        // And the way back out costs nothing.
        hud.cancelResign()
        #expect(hud.resignArmed == false)
        #expect(hud.confirmResign() == false)
        #expect(solo.session.isMatchOver == false)
        #expect(shell.route == .match(Self.setup))

        solo.leave()
    }

    @Test("A confirmed resignation ends the match and reaches results")
    func confirmedResignationEndsTheMatchAtResults() async throws {
        let (solo, _, shell, hud) = try await Self.hud()

        hud.armResign()
        #expect(hud.confirmResign())

        #expect(solo.session.isMatchOver)
        #expect(solo.session.winner == SoloMatch.peerPlayerID)
        #expect(shell.route == .results(winner: SoloMatch.peerPlayerID))
        #expect(hud.resignArmed == false)

        solo.leave()
    }

    @Test("Any other action disarms a primed resignation")
    func otherActionsDisarmResign() async throws {
        let (solo, wiring, _, hud) = try await Self.hud()

        hud.armResign()
        #expect(hud.draw() == false, "a spaced opening is not drawable")
        #expect(hud.resignArmed == false, "a refused draw left the resignation armed")

        let tile = try #require(wiring.board.placementList.first)
        Self.select(tile, on: wiring)
        hud.armResign()
        #expect(hud.swap(tile.tile))
        #expect(hud.resignArmed == false, "a swap left the resignation armed")

        solo.leave()
    }

    // MARK: - Refused completion claims

    @Test("A refused Draw counts a completion attempt and a granted one does not")
    func refusedDrawCountsACompletionAttempt() async throws {
        let dictionary = EnableWordList(words: ["GO"])
        let (host, session) = try await MatchBoardTests.guest(handSize: 2, dictionary: dictionary)
        let wiring = MatchBoard(session: session, dictionary: dictionary)
        wiring.viewport = MatchBoardTests.viewport
        let shell = ShellModel(route: .match(Self.setup))
        let hud = MatchHUDModel(shell: shell, session: session, board: wiring)

        try await MatchBoardTests.grant([Tile(letter: "G"), Tile(letter: "O")], from: host)
        try await SoloMatchTests.waitUntil("the opening on the board") {
            wiring.board.placementList.count == 2
        }

        #expect(hud.completionAttempts == 0)
        #expect(hud.draw() == false)
        #expect(hud.completionAttempts == 1, "a refused Draw explained nothing")
        // Each refusal is its own flash: the count rises again rather than
        // being re-armed from zero.
        #expect(hud.draw() == false)
        #expect(hud.completionAttempts == 2)

        let loose = try #require(wiring.board.placementList.first { $0.tile.letter == "O" })
        let joined = try #require(wiring.board.placementList.first { $0.tile.letter == "G" }).coord
        _ = wiring.board.remove(at: loose.coord)
        try wiring.board.place(loose.tile, at: Coord(row: joined.row, col: joined.col + 1))
        wiring.model.seed(wiring.board, against: dictionary)

        #expect(hud.draw())
        #expect(hud.completionAttempts == 2, "a granted Draw flashed the board")

        session.leave()
    }

    // MARK: - The win claim

    /// The claim is refused through the same counter as Draw and — refused —
    /// leaves the player in the match.
    ///
    /// It is NOT gated on what Draw is gated on. Draw needs a pool; the win
    /// call needs an empty one. On an opening board the pool is full, so
    /// `MatchHUD` does not offer the control at all — and `claimWin()` refuses
    /// anyway, so a direct caller cannot get round the gate the view reads.
    @Test("A refused claim flashes the board and ends nothing")
    func refusedClaimChangesNoRoute() async throws {
        let (solo, _, shell, hud) = try await Self.hud()

        #expect(hud.winLabel == Terminology.winCall)
        #expect(hud.isWinEnabled == false, "the claim was offered while the pool was still full")
        #expect(hud.claimWin() == false)
        #expect(hud.completionAttempts == 1, "a refused claim explained nothing")
        #expect(hud.claimWin() == false)
        #expect(hud.completionAttempts == 2, "the second refusal replayed the first flash")
        #expect(shell.route == .match(Self.setup), "a refusal is not an outcome")
        #expect(solo.session.isMatchOver == false)

        solo.leave()
    }

    @Test("An accepted claim ends the match here and routes to the results")
    func acceptedClaimRoutesToResults() async throws {
        let dictionary = EveryWordIsReal()
        let (host, session) = try await MatchBoardTests.guest(handSize: 2, dictionary: dictionary)
        let wiring = MatchBoard(session: session, dictionary: dictionary)
        wiring.viewport = MatchBoardTests.viewport
        let shell = ShellModel(route: .match(Self.setup))
        let hud = MatchHUDModel(shell: shell, session: session, board: wiring)

        try await MatchBoardTests.grant([Tile(letter: "G"), Tile(letter: "O")], from: host)
        try await SoloMatchTests.waitUntil("the opening on the board") {
            wiring.board.placementList.count == 2
        }

        // One word, one cluster: the same board state that unlocks Draw.
        let loose = try #require(wiring.board.placementList.first { $0.tile.letter == "O" })
        let joined = try #require(wiring.board.placementList.first { $0.tile.letter == "G" }).coord
        _ = wiring.board.remove(at: loose.coord)
        try wiring.board.place(loose.tile, at: Coord(row: joined.row, col: joined.col + 1))
        wiring.model.seed(wiring.board, against: dictionary)

        // The call is only offered once there is nothing left to take. The host
        // says so on the wire; there is no local way to reach that latch.
        #expect(hud.isWinEnabled == false, "the call was offered with tiles still in the pool")
        try await host.send(.poolExhausted, delivery: .reliable)
        try await SoloMatchTests.waitUntil("the pool to run out") { session.poolIsExhausted }

        #expect(hud.isWinEnabled)
        #expect(hud.claimWin())
        #expect(hud.completionAttempts == 0, "an accepted claim flashed the board")
        #expect(session.isMatchOver)
        #expect(session.winner == session.localPlayerID)
        #expect(shell.route == .results(winner: session.localPlayerID))

        // Over is over: a second press is refused and changes nothing.
        #expect(hud.claimWin() == false)
        #expect(hud.completionAttempts == 1)
        #expect(shell.route == .results(winner: session.localPlayerID))

        session.leave()
    }

    /// The win call must not be derived from Draw's gate again.
    ///
    /// `isWinEnabled` was `{ isDrawEnabled }`, which reads as tidy and is
    /// exactly backwards: Draw is disabled once the pool is out, so the control
    /// for ending the match was live for the whole match and dead at the one
    /// moment it could ever have been pressed. Every model test above passed
    /// throughout.
    @Test("The win call is not derived from the Draw gate")
    func theWinGateIsItsOwnQuestion() throws {
        let text = try String(contentsOf: Self.shellSource("MatchHUDModel.swift"), encoding: .utf8)
        #expect(!text.contains("isWinEnabled: Bool { isDrawEnabled }"),
                "the win call reads Draw's gate again — it is live when it cannot work")
        #expect(text.contains("&& session.poolIsExhausted"),
                "the win call no longer waits for the pool to run out")
    }

    /// The disable that made the flash unreachable. Folding `board.canDraw`
    /// into the gate the *button* reads swallows the very press the refusal
    /// exists to answer — and every test above still passes, because they call
    /// the model directly. A source check, because the gate is read in a
    /// SwiftUI file the macOS test target cannot compile.
    ///
    /// Two halves, because the split is what makes it safe: the view must read
    /// `isDrawPressable`, and `isDrawPressable` must not consult the board.
    @Test("The completion gate does not disable the control")
    func theGateLeavesTheControlLive() throws {
        let view = try String(contentsOf: Self.shellSource("MatchHUD.swift"), encoding: .utf8)
        #expect(view.contains(".disabled(!hud.isDrawPressable)"),
                "the Draw button reads the board's gate — the refusal press is swallowed")
        let model = try String(contentsOf: Self.shellSource("MatchHUDModel.swift"), encoding: .utf8)
        #expect(model.contains("public var isDrawPressable: Bool {\n        !session.isMatchOver"),
                "isDrawPressable gates on the board again — the refusal press is swallowed")
    }

    /// A rule the host refuses for the whole match is not a disabled control.
    ///
    /// `swapEnabled: false` means every swap request is refused from the deal
    /// to the last tile, so a Swap button gated on ``isSwapEnabled`` alone would
    /// sit greyed out the entire game, inviting a press that can never land.
    @Test("Swap is not offered at all when the rules turn it off")
    func swapIsAbsentWhenTheRulesSayNoSwap() async throws {
        let dictionary = EnableWordList(words: ["GO"])
        var noSwap = MatchOptions.standard
        noSwap.swapEnabled = false

        let (_, off) = try await MatchBoardTests.guest(
            handSize: 2, dictionary: dictionary, options: noSwap
        )
        let shell = ShellModel(route: .match(Self.setup))
        let hidden = MatchHUDModel(
            shell: shell, session: off, board: MatchBoard(session: off, dictionary: dictionary)
        )
        #expect(hidden.isSwapOffered == false, "the control is offered under rules that refuse it")

        // The standard rules still have a swap in them, so this is a rule being
        // read and not a control that went away.
        let (_, on) = try await MatchBoardTests.guest(handSize: 2, dictionary: dictionary)
        let shown = MatchHUDModel(
            shell: ShellModel(route: .match(Self.setup)),
            session: on, board: MatchBoard(session: on, dictionary: dictionary)
        )
        #expect(shown.isSwapOffered, "the standard rules lost their swap")
    }

    /// The gate is read in a SwiftUI file the macOS test target cannot compile,
    /// so the button's absence is checked against the bytes on disk. `if`, not
    /// `.disabled`: a greyed-out control for a rule that never changes is the
    /// thing this exists to prevent.
    @Test("The HUD omits the Swap button rather than disabling it")
    func theHUDOmitsSwapUnderNoSwapRules() throws {
        let text = try String(contentsOf: Self.shellSource("MatchHUD.swift"), encoding: .utf8)
        #expect(text.contains("if hud.isSwapOffered {"),
                "the Swap button is not gated on the rules — it renders under rules that refuse it")
    }

    /// The endgame gate. Below ``Pool/swapSize`` the host refuses every swap,
    /// so the control has to go dead — but the press must still LAND, or the
    /// player learns nothing from a button that stopped working. Same split as
    /// Draw, and checked the same way: the view's `.disabled` against the
    /// pressable predicate, and the model's rule against the pool's own number
    /// rather than a second copy of the `3`.
    @Test("Swap goes dead on a pool too small to answer it, but the press still lands")
    func swapIsGatedOnAPoolThatCanAnswer() throws {
        let view = try String(contentsOf: Self.shellSource("MatchHUD.swift"), encoding: .utf8)
        #expect(view.contains(".disabled(!hud.isSwapPressable)"),
                "Swap is disabled on the wrong predicate — a refused press never lands")

        let model = try String(contentsOf: Self.shellSource("MatchHUDModel.swift"), encoding: .utf8)
        #expect(model.contains("remaining >= Pool.swapSize"),
                "the swap gate does not read the pool's own swap size")
        #expect(model.contains("isSwapPressable && swappableTile != nil && poolCanServeASwap"),
                "isSwapEnabled no longer folds the pool rule in")
    }

    /// `MatchView` is a SwiftUI file the macOS test target cannot compile, so
    /// the wire is checked against the bytes on disk.
    @Test("MatchView hands the refusal count to the board")
    func matchViewPassesTheCount() throws {
        let text = try String(contentsOf: Self.shellSource("MatchView.swift"), encoding: .utf8)
        #expect(text.contains("completionAttempts: hud.completionAttempts"))
    }

    // MARK: - The guardrail

    /// Checked against the bytes on disk: neither HUD file may name the peer to
    /// the player. `peerPresence` is read by the model to gate this player's own
    /// controls, so the model is allowed that one word and nothing more; the
    /// view may not name it at all.
    /// One shell source file, as it sits on disk.
    static func shellSource(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellSrc")
            .resolvingSymlinksInPath()
            .appendingPathComponent(name)
    }

    @Test("Nothing in the HUD reports the opponent")
    func hudNamesNoOpponent() throws {
        for name in ["MatchHUDModel.swift", "MatchHUD.swift"] {
            let text = try String(contentsOf: Self.shellSource(name), encoding: .utf8)
            for banned in ["peerTileIDs", "winningPlacements", "peerPlayerID", "opponentTiles"] {
                #expect(!text.contains(banned), "\(name) reaches for \(banned)")
            }
        }
    }

    // MARK: - A refusal the player can see

    /// Draw stays pressable while the board is merely unfinished, so the press
    /// lands, the refusal is counted, and the board flashes what is wrong.
    ///
    /// Disabling it on `isDrawEnabled` made SwiftUI swallow the press: nothing
    /// counted, nothing flashed, and the opening deal — every player's first
    /// screen — read as a broken button.
    @Test("Draw stays pressable on an unfinished board, and says why")
    func drawIsPressableOnAnUnfinishedBoardAndRefusesVisibly() async throws {
        let (solo, wiring, _, hud) = try await Self.hud()

        #expect(wiring.model.canDraw == false, "the opening deal was already complete")
        #expect(hud.isDrawPressable, "a disabled button swallows the press")
        #expect(hud.isDrawEnabled == false)

        #expect(hud.draw() == false)
        #expect(hud.completionAttempts == 1, "the refusal was not counted")

        // What `BoardView` runs when that count changes.
        wiring.model.attemptedCompletion()
        #expect(
            wiring.model.flashedInvalid.isEmpty == false,
            "a refused draw lit nothing, which is the silence this fixes"
        )
        solo.leave()
    }
}
