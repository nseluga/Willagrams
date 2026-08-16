import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Live validation: the published `BoardValidation`, the coords the view tints,
/// the Draw gate, and the guardrail that none of it happens during a drag.
///
/// `BoardModel` is pure and symlinked into this package, so every case here is
/// executed against the same file the app compiles.
final class BoardValidationTests: XCTestCase {

    // MARK: - Doubles

    /// A word list that counts what was asked of it.
    ///
    /// The counter is what proves WHERE validation runs: `Board.validate` calls
    /// `contains` once per run of two or more, so zero calls across a whole drag
    /// and a non-zero count on the commit is the guardrail stated as a number.
    private final class CountingWordList: WordList, @unchecked Sendable {
        private let guardLock = NSLock()
        private var asked = 0
        private let known: Set<String>

        init(_ known: Set<String> = []) { self.known = known }

        var calls: Int {
            guardLock.lock(); defer { guardLock.unlock() }
            return asked
        }

        func contains(_ word: String) -> Bool {
            guardLock.lock(); asked += 1; guardLock.unlock()
            return known.contains(word.uppercased())
        }
    }

    private final class SilentHaptics: BoardHaptics, @unchecked Sendable {
        func fire(_ event: BoardHapticEvent) {}
    }

    // MARK: - Fixtures

    /// 48pt cells at the origin: a whole-cell step is a translation of 48 and a
    /// cell centre sits 24 in from its corner.
    private static let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
    /// Wide enough to accept any release inside a cell, which is what the real
    /// `snapThreshold` now is.
    ///
    /// It was 22, a copy of the old token, and that made every move below a coin
    /// flip: these fixtures use `Tile(letter:)`, so each tile's scatter comes
    /// from a random UUID, and a drag measured from the tile's DRAWN position
    /// carries that scatter as its residual — up to `hypot(0.4 × 48, 0.4 × 48)`
    /// ≈ 27pt for a perfectly aimed one-cell move. Above 22 the move was
    /// refused and the commit silently did nothing. That is the same arithmetic
    /// that made real drags revert on device.
    private static let threshold: CGFloat = 96
    private static let viewport = CGRect(x: 0, y: 0, width: 960, height: 960)

    /// C-A-T across row 0, plus a loose tile well clear of it.
    ///
    /// The move under test drags the loose tile onto `(0, 3)`, which turns CAT
    /// into CATS or CATZ depending on the letter — one commit, two different
    /// answers from the frozen checker.
    private static func fixture(loose: Character) -> (board: Board, loose: Coord) {
        var board = Board()
        for (offset, letter) in "CAT".enumerated() {
            try? board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }
        let looseAt = Coord(row: 4, col: 3)
        try? board.place(Tile(letter: loose), at: looseAt)
        return (board, looseAt)
    }

    /// The centre of `coord`'s cell under `camera`.
    private static func centre(of coord: Coord) -> CGPoint {
        let point = camera.point(for: coord)
        return CGPoint(x: point.x + 24, y: point.y + 24)
    }

    /// Takes hold of the tile at `from` and releases it over `to`, returning the
    /// committed board and the session that committed it.
    private func move(
        from: Coord,
        to: Coord,
        on board: Board,
        against dictionary: some WordList,
        model: inout BoardModel
    ) -> Board {
        let grab = BoardGesture.Drag(
            at: Self.centre(of: from), in: board, camera: Self.camera
        ).grab
        model.began(grab, haptics: SilentHaptics())
        let translation = CGSize(
            width: Self.centre(of: to).x - Self.centre(of: from).x,
            height: Self.centre(of: to).y - Self.centre(of: from).y
        )
        model.moved(to: translation)
        return model.commit(
            translation: translation, on: board, camera: Self.camera,
            threshold: Self.threshold, against: dictionary
        )
    }

    // MARK: - Criterion: the published validation is recomputed on every commit

    /// Two commits in a row, each one turning the answer the OTHER way. A
    /// `revalidate` deleted from `commit` leaves the seeded answer standing, and
    /// a `revalidate` that ran once and stuck leaves the first answer standing —
    /// so both halves of "after EVERY committed move" are reddened here.
    func testEveryCommittedMoveRepublishesTheValidation() throws {
        let dictionary = CountingWordList(["CAT", "CATS"])
        let start = Self.fixture(loose: "S")
        var model = BoardModel(board: start.board, against: dictionary)

        // Seeded: CAT is real, but the loose S is its own cluster, so the board
        // is not complete and nothing is refused.
        XCTAssertEqual(model.validation.clusterCount, 2)
        XCTAssertEqual(model.validation.tileCount, 4)
        XCTAssertTrue(model.invalidCoords.isEmpty)
        XCTAssertFalse(model.canDraw)

        // Move one: S lands on (0, 3). CATS is real and it is now one cluster.
        let joined = move(
            from: start.loose, to: Coord(row: 0, col: 3),
            on: start.board, against: dictionary, model: &model
        )
        XCTAssertEqual(joined.tile(at: Coord(row: 0, col: 3))?.letter, "S")
        XCTAssertEqual(model.validation.clusterCount, 1, "the published clusterCount is stale")
        XCTAssertEqual(model.validation.tileCount, 4)
        XCTAssertEqual(model.validation.invalidWords, [], "CATS reads as refused")
        XCTAssertTrue(model.invalidCoords.isEmpty)
        XCTAssertTrue(model.canDraw, "a complete board does not permit a draw")

        // Move two: the same S pulled DOWN to (1, 3). CAT is real again, the S
        // is loose again, and every published field has to move back with it.
        let parted = move(
            from: Coord(row: 0, col: 3), to: Coord(row: 1, col: 3),
            on: joined, against: dictionary, model: &model
        )
        XCTAssertNil(parted.tile(at: Coord(row: 0, col: 3)))
        XCTAssertEqual(model.validation.clusterCount, 2, "the second commit did not republish")
        XCTAssertFalse(model.canDraw, "a two-cluster board still permits a draw")
    }

    /// The published invalid set names the coords of the run the checker
    /// refused, and only those.
    func testARefusedRunPublishesEveryCoordItCoversAndNoOther() throws {
        // CAT is real, CATZ is not.
        let dictionary = CountingWordList(["CAT"])
        let start = Self.fixture(loose: "Z")
        var model = BoardModel(board: start.board, against: dictionary)

        _ = move(
            from: start.loose, to: Coord(row: 0, col: 3),
            on: start.board, against: dictionary, model: &model
        )

        XCTAssertEqual(model.validation.invalidWords.map(\.text), ["CATZ"])
        XCTAssertEqual(
            model.invalidCoords,
            Set((0...3).map { Coord(row: 0, col: $0) }),
            "the tinted set is not the coords CATZ covers"
        )
        XCTAssertFalse(model.canDraw, "a board holding a refused run permits a draw")
    }

    /// A refused run DOWN, so the direction arm of the expansion is its own
    /// case: an expansion that always walked columns would still pass the one
    /// above.
    func testARefusedRunDownExpandsAlongItsOwnDirection() throws {
        var board = Board()
        for (offset, letter) in "QX".enumerated() {
            try? board.place(Tile(letter: letter), at: Coord(row: offset, col: 5))
        }
        var loose = board
        try? loose.place(Tile(letter: "Y"), at: Coord(row: 6, col: 5))

        let dictionary = CountingWordList([])
        var model = BoardModel(board: loose, against: dictionary)
        _ = move(
            from: Coord(row: 6, col: 5), to: Coord(row: 2, col: 5),
            on: loose, against: dictionary, model: &model
        )

        XCTAssertEqual(model.validation.invalidWords.map(\.text), ["QXY"])
        XCTAssertEqual(
            model.invalidCoords,
            Set((0...2).map { Coord(row: $0, col: 5) }),
            "a run DOWN was expanded across"
        )
    }

    // MARK: - Criterion: the tint reaches the draw list, and only the bad tiles

    func testOnlyTilesInARefusedRunAreMarkedInTheDrawList() throws {
        // WILL is real; the loose Q and the refused pair are not.
        let dictionary = CountingWordList(["WILL"])
        var board = Board()
        for (offset, letter) in "WILL".enumerated() {
            try? board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }
        // A refused pair, far from WILL and from the loose tile.
        try? board.place(Tile(letter: "Q"), at: Coord(row: 5, col: 0))
        try? board.place(Tile(letter: "X"), at: Coord(row: 5, col: 1))
        // A loose tile, in no run at all.
        try? board.place(Tile(letter: "J"), at: Coord(row: 9, col: 9))

        var model = BoardModel(board: board, against: dictionary)
        // Nudge a tile and put it straight back, so the commit is a real one.
        _ = move(
            from: Coord(row: 9, col: 9), to: Coord(row: 9, col: 9),
            on: board, against: dictionary, model: &model
        )

        let cells = BoardRender.cells(
            board: board, camera: Self.camera, in: Self.viewport,
            invalid: model.invalidCoords
        )
        let marked = Set(cells.filter(\.isInvalid).map(\.coord))
        XCTAssertEqual(marked, [Coord(row: 5, col: 0), Coord(row: 5, col: 1)])

        // Stated the other way round, so an `isInvalid` wired to something that
        // happens to hold on these coords still has to be wrong somewhere.
        for valid in (0..<4).map({ Coord(row: 0, col: $0) }) {
            XCTAssertFalse(
                try XCTUnwrap(cells.first { $0.coord == valid }).isInvalid,
                "a tile in a real word is tinted"
            )
        }
        XCTAssertFalse(
            try XCTUnwrap(cells.first { $0.coord == Coord(row: 9, col: 9) }).isInvalid,
            "a loose tile is tinted"
        )
        XCTAssertFalse(
            cells.filter { $0.tile == nil }.contains(where: \.isInvalid),
            "an empty cell is tinted"
        )
    }

    func testATileInFlightIsNotTintedWhileItIsCarried() throws {
        let dictionary = CountingWordList([])
        var board = Board()
        try? board.place(Tile(letter: "Q"), at: Coord(row: 0, col: 0))
        try? board.place(Tile(letter: "X"), at: Coord(row: 0, col: 1))

        var model = BoardModel(board: board, against: dictionary)
        XCTAssertEqual(model.invalidCoords, [Coord(row: 0, col: 0), Coord(row: 0, col: 1)])

        let lifted = BoardRender.cells(
            board: board, camera: Self.camera, in: Self.viewport,
            dragging: [Coord(row: 0, col: 0)], by: CGSize(width: 10, height: 0),
            invalid: model.invalidCoords
        )
        XCTAssertFalse(
            try XCTUnwrap(lifted.first { $0.coord == Coord(row: 0, col: 0) }).isInvalid,
            "a tile under the finger reads as refused rather than as carried"
        )
        XCTAssertTrue(
            try XCTUnwrap(lifted.first { $0.coord == Coord(row: 0, col: 1) }).isInvalid,
            "the tile left behind lost its tint"
        )
    }

    // MARK: - Criterion: canDraw IS the frozen isComplete

    /// Every published `canDraw` agrees with the frozen method called directly
    /// on the committed board — across boards that differ in each of the three
    /// things `isComplete` weighs, so a `canDraw` that re-derived any one of
    /// them disagrees on at least one row.
    func testCanDrawAgreesWithTheFrozenCompletenessRuleOnEveryShape() throws {
        let dictionary = CountingWordList(["CAT", "CATS"])

        // Each case is one board, moved by one commit that puts a tile back
        // where it was, so the commit is real and the board is the shape named.
        var singleTile = Board()
        try? singleTile.place(Tile(letter: "C"), at: Coord(row: 0, col: 0))

        var refused = Board()
        for (offset, letter) in "CATZ".enumerated() {
            try? refused.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }

        var complete = Board()
        for (offset, letter) in "CATS".enumerated() {
            try? complete.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }

        let boards: [(name: String, board: Board, at: Coord)] = [
            ("a lone tile", singleTile, Coord(row: 0, col: 0)),
            ("two clusters", Self.fixture(loose: "S").board, Coord(row: 4, col: 3)),
            ("a refused run", refused, Coord(row: 0, col: 3)),
            ("a complete board", complete, Coord(row: 0, col: 3)),
        ]

        for case let (name, board, at) in boards {
            var model = BoardModel(board: board, against: dictionary)
            let after = move(from: at, to: at, on: board, against: dictionary, model: &model)
            XCTAssertEqual(
                model.canDraw,
                after.validate(against: dictionary).isComplete,
                "canDraw disagrees with the frozen rule on \(name)"
            )
            XCTAssertEqual(model.validation, after.validate(against: dictionary), "\(name)")
        }

        // And the four rows are not all the same answer, or the agreement above
        // would hold for a canDraw hardcoded either way.
        var live = BoardModel(board: complete, against: dictionary)
        _ = move(from: Coord(row: 0, col: 3), to: Coord(row: 0, col: 3),
                 on: complete, against: dictionary, model: &live)
        XCTAssertTrue(live.canDraw)
        var dead = BoardModel(board: refused, against: dictionary)
        _ = move(from: Coord(row: 0, col: 3), to: Coord(row: 0, col: 3),
                 on: refused, against: dictionary, model: &dead)
        XCTAssertFalse(dead.canDraw)
    }

    // MARK: - Guardrail: validation runs on commit only, never per frame

    func testNoWordIsCheckedWhileTheFingerIsDownAndAtLeastOneIsOnRelease() throws {
        let dictionary = CountingWordList(["CAT"])
        let start = Self.fixture(loose: "S")
        // Seeded the way `BoardView` builds it, so a model holding a board and
        // a list from construction is the one under the finger — an unseeded
        // model has nothing to check with and would read as clean either way.
        var model = BoardModel(board: start.board, against: dictionary)
        let seeded = dictionary.calls
        XCTAssertGreaterThan(seeded, 0, "seeding checked nothing, so the count below proves nothing")

        let from = start.loose
        let to = Coord(row: 0, col: 3)
        let grab = BoardGesture.Drag(
            at: Self.centre(of: from), in: start.board, camera: Self.camera
        ).grab
        model.began(grab, haptics: SilentHaptics())
        XCTAssertEqual(dictionary.calls, seeded, "taking hold of a tile checked a word")

        // Sixty frames, the way `DragGesture.onChanged` reports them.
        let full = CGSize(
            width: Self.centre(of: to).x - Self.centre(of: from).x,
            height: Self.centre(of: to).y - Self.centre(of: from).y
        )
        for frame in 1...60 {
            let progress = CGFloat(frame) / 60
            model.moved(to: CGSize(width: full.width * progress, height: full.height * progress))
        }
        XCTAssertEqual(dictionary.calls, seeded, "a word was checked mid-drag, \(dictionary.calls - seeded) extra times")

        _ = model.commit(
            translation: full, on: start.board, camera: Self.camera,
            threshold: Self.threshold, against: dictionary
        )
        XCTAssertGreaterThan(dictionary.calls, seeded, "the commit checked nothing")
    }

    /// A cancelled hold is not a committed move, so it publishes nothing — and
    /// checks nothing.
    func testACancelledHoldNeitherChecksAWordNorRepublishes() throws {
        let dictionary = CountingWordList(["CAT"])
        let start = Self.fixture(loose: "S")
        var model = BoardModel(board: start.board, against: dictionary)
        let seeded = model.validation
        let seededCalls = dictionary.calls

        let grab = BoardGesture.Drag(
            at: Self.centre(of: start.loose), in: start.board, camera: Self.camera
        ).grab
        model.began(grab, haptics: SilentHaptics())
        model.moved(to: CGSize(width: 48, height: 0))
        model.cancel()

        XCTAssertEqual(dictionary.calls, seededCalls, "a cancelled hold checked a word")
        XCTAssertEqual(model.validation, seeded)

        // And the release that follows commits nothing, so it publishes nothing.
        _ = model.commit(
            translation: CGSize(width: 48, height: 0), on: start.board,
            camera: Self.camera, threshold: Self.threshold, against: dictionary
        )
        XCTAssertEqual(dictionary.calls, seededCalls, "a release with nothing held checked a word")
    }

    // MARK: - Criterion: under 16ms on a full board

    func testRevalidatingAFullBoardStaysUnderOneFrame() throws {
        // 144 tiles: a 12 x 12 block of real three-letter runs across, so the
        // checker has 96 runs to look up rather than one long one.
        var board = Board()
        for row in 0..<12 {
            for col in 0..<12 {
                let letter = ["C", "A", "T"][col % 3].first!
                try? board.place(Tile(letter: letter), at: Coord(row: row * 2, col: col))
            }
        }
        XCTAssertEqual(board.placements.count, 144)

        let dictionary = EnableWordList(words: ["CAT", "AT", "CA", "TC", "ATC", "TCA"])
        var model = BoardModel(board: board, against: dictionary)

        var samples: [Double] = []
        for _ in 0..<5 {
            // One committed move, put back where it came from, so each run is
            // the whole seam: drop, revalidate, republish.
            let at = Coord(row: 0, col: 0)
            let grab = BoardGesture.Drag(
                at: Self.centre(of: at), in: board, camera: Self.camera
            ).grab
            model.began(grab, haptics: SilentHaptics())
            let started = DispatchTime.now().uptimeNanoseconds
            _ = model.commit(
                translation: .zero, on: board, camera: Self.camera,
                threshold: Self.threshold, against: dictionary
            )
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }

        let median = samples.sorted()[samples.count / 2]
        XCTAssertLessThan(median, 16, "revalidate + republish took \(median)ms, samples \(samples)")
        XCTAssertGreaterThan(model.validation.tileCount, 0, "the run under the clock validated nothing")
        print("median revalidate+republish on 144 tiles: \(median)ms, samples \(samples)")
    }
}
