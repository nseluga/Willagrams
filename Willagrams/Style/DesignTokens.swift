import SwiftUI

/// Every visual constant in the app. Frozen key names, placeholder values.
///
/// The style lane replaces the values and the art; it does not rename the
/// keys. Board and shell read from here and never hardcode a color, a radius,
/// or a duration.
public enum DesignTokens {

    public enum Palette {
        public static let tileFace = Color(red: 0.98, green: 0.96, blue: 0.90)
        public static let tileEdge = Color(red: 0.85, green: 0.81, blue: 0.72)
        public static let tileLetter = Color(red: 0.15, green: 0.13, blue: 0.11)
        public static let boardSurface = Color(red: 0.22, green: 0.28, blue: 0.24)
        public static let accent = Color(red: 0.20, green: 0.60, blue: 0.45)
        public static let danger = Color(red: 0.78, green: 0.25, blue: 0.22)
        public static let textPrimary = Color(red: 0.10, green: 0.10, blue: 0.10)
        public static let textSecondary = Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 40
    }

    public enum Radius {
        public static let tile: CGFloat = 6
        public static let panel: CGFloat = 14
    }

    public enum Typography {
        public static let tileLetter = Font.system(size: 28, weight: .semibold, design: .rounded)
        public static let title = Font.system(size: 28, weight: .bold)
        public static let body = Font.system(size: 17)
        public static let caption = Font.system(size: 13)
    }

    public enum Motion {
        public static let snapDuration: Double = 0.16
        public static let dealDuration: Double = 0.45

        /// How near an occupied edge a dragged tile must be released before it
        /// clicks into place, in points.
        ///
        /// This is the magnetic feel, and it is the knob to turn when tiles
        /// snap too eagerly or not eagerly enough. Too low and placing feels
        /// fiddly; too high and tiles jump to cells the player did not mean.
        public static let snapThreshold: CGFloat = 22
    }
}
