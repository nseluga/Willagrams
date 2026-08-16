import Foundation
import CoreGraphics
import WillagramsRules

/// Which tiles the player has swept up, and whether the surface is sweeping at
/// all.
///
/// View state and nothing else. Painting reads `Board` to find out where the
/// tiles are and never writes to it: a swept-up set is a drawing decision until
/// a group drag lands, and the only thing that ever changes the board is
/// `TileDrag`, on release. That is why `paint` takes `board` by value — there is
/// no parameter here a mutation could travel out through.
///
/// Pure Foundation/CoreGraphics, so `Tests/BoardTests` executes every decision
/// below with no host app — same reason `BoardGesture`, `BoardRender` and
/// `BoardModel` exist.
public struct BoardSelection: Equatable, Sendable {

    /// Whether a one-finger drag paints rather than pans.
    ///
    /// Separate from "the set is empty": a player who has entered the mode and
    /// swept nothing yet is still in it, and a sweep that crosses no tile must
    /// not read as never having entered.
    public private(set) var isActive: Bool = false

    /// The swept-up coords. Only ever holds coords that carried a tile at the
    /// moment they were painted.
    public private(set) var coords: Set<Coord> = []

    /// The only way in is `enter` and `paint`. There is deliberately no
    /// initializer that takes a set: a selection nobody swept is a fixture that
    /// proves nothing, and an inactive selection holding coords is a state the
    /// rest of this type would have to keep answering for.
    public init() {}

    public var isEmpty: Bool { coords.isEmpty }

    public func contains(_ coord: Coord) -> Bool { coords.contains(coord) }

    /// Enters selection mode. Idempotent, and never touches what is already
    /// swept up — re-entering mid-selection is not a reason to lose it.
    public mutating func enter() {
        isActive = true
    }

    /// Leaves selection mode AND drops the set, in one call.
    ///
    /// One method rather than two because they must never be taken apart: a
    /// mode left with a set still in it draws tiles as selected that no drag
    /// can move, and a set dropped without leaving the mode leaves the player
    /// sweeping in a mode they asked to be out of.
    public mutating func clear() {
        isActive = false
        coords = []
    }

    /// The set after a committed group move, which is the same tiles at new
    /// coords. Refused while inactive so nothing can put a set behind the
    /// player's back.
    public mutating func replace(with landed: Set<Coord>) {
        guard isActive else { return }
        coords = landed
    }

    /// Paints every tile the segment from `start` to `end` crosses, and answers
    /// how many tiles it crossed — crossed, not newly added, so re-sweeping
    /// ground already swept still counts as having swept something. That is
    /// what lets the caller tell a tap on empty space from a sweep back over
    /// the selection.
    ///
    /// A segment rather than a point because `DragGesture` reports maybe sixty
    /// positions a second and a fast finger jumps whole cells between two of
    /// them. Sampling the line between the last position and this one is what
    /// makes "every tile it crosses" true of the sweep rather than of the
    /// frames that happened to be delivered.
    ///
    /// ponytail: samples at half a cell, so a corner clipped for less than that
    /// can be missed. Walk the cells the segment actually pierces (a supercover
    /// line) when a session shows a missed corner mattering.
    @discardableResult
    public mutating func paint(
        from start: CGPoint,
        to end: CGPoint,
        on board: Board,
        camera: BoardCamera,
        offsets: [UUID: CGSize] = [:]
    ) -> Int {
        // Refused outright when the mode is off. Painting is the only way into
        // the set, so this is what makes an ordinary drag unable to select
        // anything at all.
        guard isActive else { return 0 }

        // Live gesture floats. Every comparison against a NaN is false, so it
        // is refused here rather than reasoned about at each step below.
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite
        else { return 0 }

        let size = camera.cellSize
        guard size > 0, size.isFinite else { return 0 }

        let span = hypot(end.x - start.x, end.y - start.y)
        guard span.isFinite else { return 0 }

        // Half a cell per sample: any cell the segment spends more than that
        // inside gets a sample. `Int(...)` is a runtime crash past `Int.max` in
        // Swift, never a clamp, so the count is bounded BEFORE the conversion.
        // The cap is a whole screen of cells many times over — a real sweep
        // never reaches it, and a garbage one is coarsely sampled rather than
        // fatal.
        let wanted = (span / (size / 2)).rounded(.up)
        let steps = wanted >= CGFloat(Self.sampleCap) ? Self.sampleCap : max(Int(wanted), 0)

        var crossed = 0
        var visited: Set<Coord> = []
        for step in 0...steps {
            let ratio = steps == 0 ? 0 : CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * ratio,
                y: start.y + (end.y - start.y) * ratio
            )
            // The tile DRAWN under the sample, not the cell the sample is
            // indexed to. A scattered tile overhangs a neighbouring cell, and
            // sweeping by cell would miss the part of it the finger actually
            // crossed while sweeping up an empty cell it never touched.
            // `BoardHit` also refuses a sample too far out to index, which is
            // what stops a stray point sweeping up whatever sits at the origin.
            guard let hit = BoardHit.tile(
                under: point, on: board, offsets: offsets, camera: camera
            ) else { continue }
            guard visited.insert(hit.coord).inserted else { continue }
            crossed += 1
            coords.insert(hit.coord)
        }
        return crossed
    }

    /// Bound on samples per reported gesture step. Named rather than inline so
    /// the number the `Int` conversion is protected by is legible.
    private static let sampleCap = 4096
}
