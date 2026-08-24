import SwiftUI

/// Every visual constant in the app.
///
/// Key names are frozen — board and shell compile against them. This lane owns
/// the values. Colors resolve through Asset Catalog Color Sets under
/// `Assets.xcassets/Colors/`, one per token, each carrying an Any and a Dark
/// appearance; no Swift here branches on `colorScheme` and no hex literal
/// lives outside the `.colorset` JSON.
public enum DesignTokens {

    public enum Palette {

        // MARK: Ground

        /// Top of the tabletop gradient.
        public static let canvasTop = Color("canvasTop")
        /// Bottom of the tabletop gradient.
        public static let canvasBottom = Color("canvasBottom")
        /// The playing surface the grid is drawn on.
        public static let boardSurface = Color("boardSurface")
        /// Raised panels: cards, sheets, the rack.
        public static let surface = Color("surface")
        /// An empty grid cell.
        public static let cellEmpty = Color("cellEmpty")

        // MARK: Ink

        /// Body text, and the fill of the loudest control.
        ///
        /// In dark this becomes cream, so the primary button keeps reading as
        /// the loudest thing on screen rather than dissolving into the ground.
        public static let ink = Color("ink")
        /// Labels drawn on top of `ink`.
        public static let onInk = Color("onInk")
        /// Alias of `ink`, kept because board and shell name it.
        public static let textPrimary = ink
        /// Secondary and metadata text.
        public static let textSecondary = Color("textSecondary")
        /// One-point borders and dividers.
        public static let hairline = Color("hairline")

        // MARK: Tiles

        public static let tileFace = Color("tileFace")
        /// The bottom bevel band. Tiles dim rather than invert in dark, so this
        /// stays a dark edge in both themes.
        public static let tileEdge = Color("tileEdge")
        public static let tileLetter = Color("tileLetter")

        // MARK: Accent

        public static let accent = Color("accent")
        public static let accentPressed = Color("accentPressed")
        /// Labels drawn on top of `accent`. Flips to dark in the dark theme —
        /// cream on the brightened gold measures ~2.1:1 and fails WCAG AA.
        public static let onAccent = Color("onAccent")
        public static let danger = Color("danger")

        // MARK: Shadow tints
        //
        // Warm-black in light, true black in dark: a warm shadow reads as a
        // smudge once the ground is already dark.

        public static let shadowTile = Color("shadowTile")
        public static let shadowCard = Color("shadowCard")
        public static let shadowButton = Color("shadowButton")
        public static let shadowSelected = Color("shadowSelected")
        /// A one-point lit top edge, standing in for the card's offset shadow
        /// in dark where an offset shadow reads as nothing.
        public static let topHighlight = Color("topHighlight")
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 40
    }

    /// Line weights. Small and deliberate — the direction leans on edges, not fills.
    public enum Stroke {
        public static let hairline: CGFloat = 1
        /// Height of the tile's bottom bevel band.
        public static let bevel: CGFloat = 3
        /// The selected-tile ring.
        public static let selectedRing: CGFloat = 2.5
    }

    public enum Radius {
        /// Board cells sit one point tighter than the tiles that land in them.
        public static let cell: CGFloat = 4
        public static let tile: CGFloat = 5
        public static let panel: CGFloat = 5
        public static let pill: CGFloat = 999
    }

    public enum Typography {
        public static let display = Font.brand(weight: .bold, size: 44)
        /// −0.03em at 44pt. The tight display tracking is most of what makes
        /// the wordmark read as Instrument Sans rather than as a grotesque.
        public static let displayTracking: CGFloat = -1.32

        public static let title = Font.brand(weight: .semibold, size: 28)
        public static let body = Font.brand(weight: .regular, size: 17)
        public static let caption = Font.brand(weight: .regular, size: 13)
        /// Every control in the app reads this — the three button styles all
        /// take their font from here, so the size of a button is one number
        /// rather than three.
        public static let button = Font.brand(weight: .semibold, size: 20)
        public static let tileLetter = Font.brand(weight: .semibold, size: 28)

        /// Fragment Mono, for uppercase metadata labels.
        public static let monoLabel = Font.mono(size: 12)
        /// Tracking that keeps uppercase mono labels from crowding.
        public static let monoLabelTracking: CGFloat = 0.8
    }

    /// The three shadow recipes, plus the selected-tile lift.
    ///
    /// SwiftUI's `.shadow` takes a blur radius where CSS takes a blur diameter,
    /// so each `radius` here is half the recipe's blur.
    public enum Shadow {
        public struct Recipe: Sendable {
            public let color: Color
            public let radius: CGFloat
            public let x: CGFloat
            public let y: CGFloat

            public init(color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) {
                self.color = color
                self.radius = radius
                self.x = x
                self.y = y
            }
        }

        /// `0 2px 5px` under a resting tile.
        public static let tile = Recipe(color: Palette.shadowTile, radius: 2.5, x: 0, y: 2)
        /// `4px 5px 0` — hard offset, zero blur. The most characteristic mark
        /// in the direction, and the one that disappears in dark.
        public static let card = Recipe(color: Palette.shadowCard, radius: 0, x: 4, y: 5)
        /// `0 5px 14px` under the primary button.
        public static let button = Recipe(color: Palette.shadowButton, radius: 7, x: 0, y: 5)
        /// `0 8px 18px` under a lifted tile.
        public static let selected = Recipe(color: Palette.shadowSelected, radius: 9, x: 0, y: 8)
        /// No shadow — for anything seated flush against its ground.
        public static let flush = Recipe(color: .clear, radius: 0, x: 0, y: 0)
    }

    public enum Motion {
        /// The standard ease for a tile settling into place.
        public static let snap = Animation.easeOut(duration: snapDuration)

        public static let snapDuration: Double = 0.16
        public static let dealDuration: Double = 0.45

        /// How far a selected tile rises off the board, in points. Negative is up.
        public static let tileLift: CGFloat = -8

        /// How far off a cell's centre a tile may be released and still land on
        /// it, in points.
        ///
        /// Large enough to cover a whole cell at every zoom: the furthest a
        /// release can fall from the nearest cell's centre is half a cell
        /// diagonally, `hypot(36, 36) ≈ 51` at the 72pt ceiling. So every drop
        /// lands, and a tile is refused only when the cell is genuinely taken.
        ///
        /// It was 22 against a 48pt cell, which is an acceptance circle over
        /// two thirds of the cell's area — a third of all releases reverted,
        /// and the faster the drag the likelier the release fell in the band.
        /// There is no "too far" to refuse here: the nearest cell has already
        /// been chosen by the time this is read, so a distance refusal only
        /// ever threw away a drop the player had already aimed.
        public static let snapThreshold: CGFloat = 96
    }
}

public extension View {
    /// Applies one of the shadow recipes.
    func brandShadow(_ recipe: DesignTokens.Shadow.Recipe) -> some View {
        shadow(color: recipe.color, radius: recipe.radius, x: recipe.x, y: recipe.y)
    }
}
