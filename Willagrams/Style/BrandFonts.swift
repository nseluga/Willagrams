import CoreText
import SwiftUI

/// The bundled type families, registered at launch.
///
/// The TTFs ship as loose resources under `Resources/Branding/Fonts/` and are
/// registered with CoreText at runtime rather than declared in Info.plist —
/// an Info.plist font key would mean editing `project.pbxproj`, which the lane
/// map forbids.
///
/// Faces are addressed by **PostScript name**, not by family plus weight.
/// Google's static Instrument Sans cuts do not share one family: Regular and
/// Bold report `Instrument Sans`, while Medium and SemiBold report
/// `Instrument Sans Medium` / `Instrument Sans SemiBold`. Asking for family
/// `Instrument Sans` at `.semibold` would therefore synthesise a fake bold off
/// the Regular cut instead of loading the real one.
public enum BrandFonts {

    /// The five bundled faces, by PostScript name.
    public enum Face: String, CaseIterable, Sendable {
        case sansRegular  = "InstrumentSans-Regular"
        case sansMedium   = "InstrumentSans-Medium"
        case sansSemiBold = "InstrumentSans-SemiBold"
        case sansBold     = "InstrumentSans-Bold"
        case monoRegular  = "FragmentMono-Regular"

        /// The file basename, which happens to match the PostScript name.
        var fileName: String { rawValue }
    }

    /// Where the app looks for the TTFs.
    ///
    /// A synchronized folder group flattens resources into the bundle root, so
    /// the subdirectory lookup is the fallback rather than the primary.
    public static func url(for face: Face, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: face.fileName, withExtension: "ttf")
            ?? bundle.url(forResource: face.fileName, withExtension: "ttf", subdirectory: "Branding/Fonts")
            ?? bundle.url(forResource: face.fileName, withExtension: "ttf", subdirectory: "Resources/Branding/Fonts")
    }

    /// Registers the bundled faces exactly once per process.
    ///
    /// `Font.brand` and `Font.mono` both route through this, so a face can
    /// never be asked for before it exists — the failure mode this guards is a
    /// silent fall back to San Francisco, which looks plausible enough to ship.
    @discardableResult
    public static func registerOnce() -> [Face] { onceResult }

    private static let onceResult: [Face] = register()

    /// Registers every bundled face with CoreText. Idempotent.
    ///
    /// Returns the faces that failed to register, so a caller — or a test —
    /// can tell a silent fallback to San Francisco from a real load.
    @discardableResult
    public static func register(in bundle: Bundle = .main) -> [Face] {
        Face.allCases.filter { !register($0, in: bundle) }
    }

    private static func register(_ face: Face, in bundle: Bundle) -> Bool {
        guard let url = url(for: face, in: bundle),
              let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider)
        else { return false }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(font, &error) { return true }

        // Already registered is success, not failure — register() is idempotent
        // and previews re-enter it.
        guard let cfError = error?.takeRetainedValue() else { return false }
        return CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue
    }
}

public extension Font {

    /// Instrument Sans at the nearest bundled weight.
    static func brand(weight: Font.Weight = .regular, size: CGFloat) -> Font {
        BrandFonts.registerOnce()
        return .custom(BrandFonts.face(for: weight).rawValue, fixedSize: size)
    }

    /// Fragment Mono, the uppercase-metadata face.
    static func mono(size: CGFloat) -> Font {
        BrandFonts.registerOnce()
        return .custom(BrandFonts.Face.monoRegular.rawValue, fixedSize: size)
    }
}

extension BrandFonts {
    /// Maps a SwiftUI weight onto the four bundled sans cuts.
    ///
    /// Anything lighter than medium reads as Regular and anything heavier than
    /// semibold reads as Bold; there are no other cuts to fall back to, and a
    /// synthesised weight is worse than the nearest real one.
    static func face(for weight: Font.Weight) -> Face {
        switch weight {
        case .medium: .sansMedium
        case .semibold: .sansSemiBold
        case .bold, .heavy, .black: .sansBold
        default: .sansRegular
        }
    }
}
