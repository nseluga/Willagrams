import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Repo-root anchor via `#filePath`, direct known-path file reads only — no
/// directory walk, so no sibling-worktree false-regression risk.
private enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Cases
        .deletingLastPathComponent()   // BoardTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    static let boardCameraSource = root.appendingPathComponent("Willagrams/Board/BoardCamera.swift")
}

final class BoardCameraTests: XCTestCase {

    // MARK: - Criterion 1: round trip, row/col -500...500, zoom 0.5...3.0

    func testRoundTripAcrossRangeAndZoom() {
        let zooms: [CGFloat] = [0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0]
        for zoom in zooms {
            let camera = BoardCamera(pan: CGSize(width: 137.25, height: -58.75), zoom: zoom, baseCellSize: 48)
            var row = -500
            while row <= 500 {
                var col = -500
                while col <= 500 {
                    let c = Coord(row: row, col: col)
                    XCTAssertEqual(camera.coord(at: camera.point(for: c)), c, "zoom \(zoom) row \(row) col \(col)")
                    col += 47
                }
                row += 53
            }
        }
    }

    func testRoundTripAtSubCellPan() {
        // Non-integer pan offsets (sub-cell pan) — round trip must still hold.
        let pans: [CGSize] = [
            CGSize(width: 0.3, height: 0.7),
            CGSize(width: -12.9, height: 5.1),
            CGSize(width: 1000.25, height: -999.75),
        ]
        for pan in pans {
            let camera = BoardCamera(pan: pan, zoom: 1.37, baseCellSize: 48)
            for row in stride(from: -500, through: 500, by: 61) {
                for col in stride(from: -500, through: 500, by: 59) {
                    let c = Coord(row: row, col: col)
                    XCTAssertEqual(camera.coord(at: camera.point(for: c)), c, "pan \(pan) row \(row) col \(col)")
                }
            }
        }
    }

    // MARK: - Criterion 2: no clamping toward origin

    func testNoOriginClamping() {
        let camera = BoardCamera()
        let a = camera.point(for: Coord(row: -40, col: -40))
        let b = camera.point(for: Coord(row: 40, col: 40))
        XCTAssertNotEqual(a, b)
        XCTAssertLessThan(a.x, 0)
        XCTAssertLessThan(a.y, 0)
        XCTAssertGreaterThan(b.x, 0)
        XCTAssertGreaterThan(b.y, 0)
    }

    // MARK: - Criterion 3: visibleCoords exact set, brute-force verified

    /// Independently derives the exact expected coord set for `rect` by
    /// scanning a generously padded candidate range and testing true
    /// half-open rect overlap per cell. Does not call `visibleCoords` or
    /// reuse its min/maxCol formula.
    private func bruteForceVisible(camera: BoardCamera, rect: CGRect) -> Set<Coord> {
        let size = camera.cellSize
        let localMinX = rect.minX - camera.pan.width
        let localMaxX = rect.maxX - camera.pan.width
        let localMinY = rect.minY - camera.pan.height
        let localMaxY = rect.maxY - camera.pan.height

        let pad = 5
        let colRange = (Int(localMinX / size) - pad)...(Int(localMaxX / size) + pad)
        let rowRange = (Int(localMinY / size) - pad)...(Int(localMaxY / size) + pad)

        var result = Set<Coord>()
        for row in rowRange {
            for col in colRange {
                let cellMinX = CGFloat(col) * size
                let cellMinY = CGFloat(row) * size
                if cellMinX < localMaxX && localMinX < cellMinX + size &&
                    cellMinY < localMaxY && localMinY < cellMinY + size {
                    result.insert(Coord(row: row, col: col))
                }
            }
        }
        return result
    }

    private func assertVisibleCoordsExact(_ camera: BoardCamera, _ rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let actual = Array(camera.visibleCoords(in: rect))
        let expected = bruteForceVisible(camera: camera, rect: rect)
        XCTAssertEqual(Set(actual), expected, "visibleCoords set mismatch", file: file, line: line)
        XCTAssertEqual(actual.count, Set(actual).count, "duplicates in visibleCoords result", file: file, line: line)
    }

    func testVisibleCoordsExactSetAtOrigin() {
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        assertVisibleCoordsExact(camera, CGRect(x: 0, y: 0, width: 1024, height: 768))
    }

    func testVisibleCoordsExactSetShifted500CellsMatchesOriginCount() {
        let base = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let size = base.cellSize
        let shifted = BoardCamera(pan: CGSize(width: -500 * size, height: -500 * size), zoom: 1, baseCellSize: 48)
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        assertVisibleCoordsExact(shifted, rect)
        XCTAssertEqual(Array(shifted.visibleCoords(in: rect)).count, Array(base.visibleCoords(in: rect)).count)
    }

    func testVisibleCoordsExactSetFractionalOffsetAndZoom() {
        let camera = BoardCamera(pan: CGSize(width: 13.7, height: -22.3), zoom: 1.83, baseCellSize: 48)
        assertVisibleCoordsExact(camera, CGRect(x: 50, y: 100, width: 900, height: 650))
    }

    func testVisibleCoordsExactSetRectEdgesCutThroughCells() {
        // Rect deliberately not grid-aligned so edges land mid-cell.
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let size = camera.cellSize
        let rect = CGRect(x: size * 1.5, y: size * 0.5, width: size * 2.25, height: size * 1.75)
        assertVisibleCoordsExact(camera, rect)
    }

    // MARK: - Criterion 4: recenter

    func testRecenterFramesCoordsInRectWithinZoomClamp() {
        let camera = BoardCamera(pan: CGSize(width: 900, height: -400), zoom: 2.7, baseCellSize: 48)
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let coords = [Coord(row: -3, col: -3), Coord(row: 3, col: 4), Coord(row: 0, col: 0)]
        let recentered = camera.recenter(over: coords, in: rect)

        XCTAssertGreaterThanOrEqual(recentered.cellSize, BoardCamera.minCellSize)
        XCTAssertLessThanOrEqual(recentered.cellSize, BoardCamera.maxCellSize)
        for c in coords {
            XCTAssertTrue(rect.contains(recentered.point(for: c)), "\(c) not inside \(rect)")
        }
    }

    func testRecenterSingleCoord() {
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let recentered = camera.recenter(over: [Coord(row: 250, col: -300)], in: rect)
        XCTAssertGreaterThanOrEqual(recentered.cellSize, BoardCamera.minCellSize)
        XCTAssertLessThanOrEqual(recentered.cellSize, BoardCamera.maxCellSize)
        XCTAssertTrue(rect.contains(recentered.point(for: Coord(row: 250, col: -300))))
    }

    func testRecenterSpansNegativeAndPositiveQuadrants() {
        // Span sized to fit within `rect` even at the 24pt cell-size floor
        // (1200/24=50 cols, 900/24=37 rows available) — a sprawl too big to
        // fit at minCellSize is a separate, engineer-flagged degenerate case
        // (see Not Verifiable in the report), not what this check targets.
        let camera = BoardCamera(pan: CGSize(width: -50, height: 300), zoom: 0.6, baseCellSize: 48)
        let rect = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let coords = [
            Coord(row: -12, col: -8), Coord(row: 12, col: 8),
            Coord(row: -5, col: 6), Coord(row: 9, col: -3),
        ]
        let recentered = camera.recenter(over: coords, in: rect)
        XCTAssertGreaterThanOrEqual(recentered.cellSize, BoardCamera.minCellSize)
        XCTAssertLessThanOrEqual(recentered.cellSize, BoardCamera.maxCellSize)
        for c in coords {
            XCTAssertTrue(rect.contains(recentered.point(for: c)), "\(c) not inside \(rect)")
        }
    }

    // MARK: - Probe (a): floorEpsilon vs visibleCoords boundary agreement

    func testCoordAtAgreesWithVisibleCoordsAtCellBoundary() {
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let size = camera.cellSize
        let k = 7 // arbitrary boundary column

        // visibleCoords' own half-open rule: a sliver strictly left of the
        // boundary belongs to column k-1 only.
        let hair: CGFloat = 1e-10
        let sliverRect = CGRect(x: CGFloat(k) * size - hair, y: 0, width: hair, height: size)
        let sliverCols = Set(camera.visibleCoords(in: sliverRect).map(\.col))
        XCTAssertEqual(sliverCols, Set([k - 1]), "visibleCoords half-open rule for a sliver just below the boundary")

        // coord(at:) for a point in that same sliver should agree.
        let justBelowCol = camera.coord(at: CGPoint(x: CGFloat(k) * size - hair, y: 0)).col
        XCTAssertEqual(justBelowCol, k - 1,
            "coord(at:) disagrees with visibleCoords just below a cell boundary — floorEpsilon (1e-9) is ~10x the \(hair) offset tested and pulls this point into column \(k) instead of \(k - 1)")

        // Exactly on the boundary, and a hair above: both read column k.
        XCTAssertEqual(camera.coord(at: CGPoint(x: CGFloat(k) * size, y: 0)).col, k)
        XCTAssertEqual(camera.coord(at: CGPoint(x: CGFloat(k) * size + hair, y: 0)).col, k)
    }

    // MARK: - Probe (b): negative-coordinate correctness

    func testNegativeCoordinatesAtCellOriginMidpointAndJustBelowBoundary() {
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let size = camera.cellSize

        for col in [-3, -2, -1, 0, 1, 2, 3] {
            let origin = camera.point(for: Coord(row: 0, col: col))
            XCTAssertEqual(camera.coord(at: origin).col, col, "cell-origin col \(col)")

            let mid = CGPoint(x: origin.x + size / 2, y: origin.y)
            XCTAssertEqual(camera.coord(at: mid).col, col, "midpoint col \(col)")

            let justBelow = CGPoint(x: origin.x - 0.5, y: origin.y)
            XCTAssertEqual(camera.coord(at: justBelow).col, col - 1, "just-below col \(col)")
        }

        // Same for rows, with a nonzero pan to rule out an origin-only fluke.
        let panned = BoardCamera(pan: CGSize(width: 30, height: -17), zoom: 1, baseCellSize: 48)
        let pSize = panned.cellSize
        for row in [-3, -2, -1, 0, 1, 2, 3] {
            let origin = panned.point(for: Coord(row: row, col: 0))
            XCTAssertEqual(panned.coord(at: origin).row, row, "panned cell-origin row \(row)")
            let mid = CGPoint(x: origin.x, y: origin.y + pSize / 2)
            XCTAssertEqual(panned.coord(at: mid).row, row, "panned midpoint row \(row)")
            let justBelow = CGPoint(x: origin.x, y: origin.y - 0.5)
            XCTAssertEqual(panned.coord(at: justBelow).row, row - 1, "panned just-below row \(row)")
        }
    }

    // MARK: - Cell size clamp

    func testCellSizeClampBoundsAtExtremeZoom() {
        let tiny = BoardCamera(zoom: 0.0001, baseCellSize: 48)
        XCTAssertEqual(tiny.cellSize, BoardCamera.minCellSize)

        let huge = BoardCamera(zoom: 1000, baseCellSize: 48)
        XCTAssertEqual(huge.cellSize, BoardCamera.maxCellSize)
    }

    // MARK: - No caching across pan/zoom mutation

    func testNoCachingAcrossPanAndZoomMutation() {
        var camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let before = camera.point(for: Coord(row: 1, col: 1))
        let sizeBefore = camera.cellSize

        camera.pan = CGSize(width: 500, height: -500)
        camera.zoom = 1.5

        let after = camera.point(for: Coord(row: 1, col: 1))
        let sizeAfter = camera.cellSize

        XCTAssertNotEqual(before, after, "point(for:) must reflect the mutated pan/zoom immediately")
        XCTAssertNotEqual(sizeBefore, sizeAfter, "cellSize must reflect the mutated zoom immediately")
        XCTAssertEqual(sizeAfter, min(max(48 * 1.5, BoardCamera.minCellSize), BoardCamera.maxCellSize))
    }

    // MARK: - Guardrails

    func testImportsAreFoundationCoreGraphicsWillagramsRulesOnly() throws {
        let source = try String(contentsOf: Repo.boardCameraSource, encoding: .utf8)
        let importLines = source.split(separator: "\n").filter { $0.hasPrefix("import ") }
        let allowed: Set<Substring> = ["import Foundation", "import CoreGraphics", "import WillagramsRules"]
        for line in importLines {
            XCTAssertTrue(allowed.contains(line), "unexpected import: \(line)")
        }
        XCTAssertFalse(source.contains("import SwiftUI"))
        XCTAssertFalse(source.contains("import UIKit"))
    }

    func testNoBannedVocabularyOrGameKitReferences() throws {
        // Scans BoardCamera.swift (the production file) only — this test
        // file's own banned-word literal below would otherwise self-flag.
        // A direct `grep -i` over both files for these terms (run manually
        // during QA) confirmed zero hits outside this literal.
        let source = try String(contentsOf: Repo.boardCameraSource, encoding: .utf8)
        let banned = ["bunch", "split", "peel", "dump", "bananas", "rotten", "gamekit", "gkmatch", "gkpeer", "gksession"]
        let lower = source.lowercased()
        for word in banned {
            XCTAssertFalse(lower.contains(word), "banned term '\(word)' found")
        }
    }

    // MARK: - Degenerate input must not trap

    // `Int(floor(.nan))` and `Int(_:)` past `Int.max` are runtime crashes in
    // Swift, not clamps, and these entry points take live gesture translations
    // and geometry-proxy rects. Reaching the end of each test is the assertion:
    // an unguarded conversion crashes the whole run rather than failing.

    func testCoordAtNonFinitePointDoesNotTrap() {
        let camera = BoardCamera()
        for bad: CGFloat in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            _ = camera.coord(at: CGPoint(x: bad, y: 0))
            _ = camera.coord(at: CGPoint(x: 0, y: bad))
            _ = camera.coord(at: CGPoint(x: bad, y: bad))
        }
    }

    func testVisibleCoordsWithNonFiniteRectIsEmptyAndDoesNotTrap() {
        let camera = BoardCamera()
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                Array(camera.visibleCoords(in: CGRect(x: 0, y: 0, width: bad, height: 100))).count, 0)
            XCTAssertEqual(
                Array(camera.visibleCoords(in: CGRect(x: bad, y: 0, width: 100, height: 100))).count, 0)
        }
    }

    func testRecenterWithZeroBaseCellSizeLeavesCameraUnchanged() {
        // baseCellSize 0 would make zoom infinite, and the next cellSize read
        // NaN — which min/max does not filter, since NaN comparisons are false.
        let camera = BoardCamera(pan: CGSize(width: 5, height: 7), zoom: 1, baseCellSize: 0)
        let result = camera.recenter(over: [Coord(row: 0, col: 0)], in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(result.pan, camera.pan)
        XCTAssertEqual(result.zoom, camera.zoom)
        XCTAssertTrue(result.cellSize.isFinite)
    }

    func testRecenterWithDegenerateRectLeavesCameraUnchanged() {
        let camera = BoardCamera()
        let coords = [Coord(row: -3, col: -3), Coord(row: 3, col: 3)]
        for rect in [
            CGRect(x: 0, y: 0, width: 0, height: 600),
            CGRect(x: 0, y: 0, width: 800, height: 0),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 600),
        ] {
            let result = camera.recenter(over: coords, in: rect)
            XCTAssertEqual(result.pan, camera.pan)
            XCTAssertEqual(result.zoom, camera.zoom)
        }
    }

    func testCellSizeStaysFiniteAfterRecenterOnDegenerateInput() {
        let camera = BoardCamera(baseCellSize: 0)
            .recenter(over: [Coord(row: 1, col: 1)], in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(camera.cellSize.isFinite)
        _ = camera.coord(at: CGPoint(x: 10, y: 10))
    }
}
