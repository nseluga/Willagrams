import Foundation
import Testing

/// Guards the asset catalog against its silent failure mode.
///
/// A missing or misspelled color set does not error at runtime — `Color("x")`
/// resolves to clear, so a whole surface renders wrong with nothing in the
/// log. These tests enumerate the semantic tokens and fail loudly instead.
@Suite("Color sets")
struct ColorSetTests {

    /// The pinned palette, verbatim from the design direction.
    /// `(light, dark)`, each `(hex, alpha)`.
    static let palette: [String: (light: (String, Double), dark: (String, Double))] = [
        "canvasTop":     (("FAF4E2", 1), ("1A1710", 1)),
        "canvasBottom":  (("F3EAD2", 1), ("14120C", 1)),
        "boardSurface":  (("F8F1DC", 1), ("17140E", 1)),
        "surface":       (("FEFAEF", 1), ("241F16", 1)),
        "ink":           (("2C2718", 1), ("F0E7D0", 1)),
        "onInk":         (("FAF4E2", 1), ("1A1710", 1)),
        "tileFace":      (("EADCB6", 1), ("D6C39A", 1)),
        "tileLetter":    (("2C2718", 1), ("221E14", 1)),
        "accent":        (("C2841B", 1), ("D9A03C", 1)),
        "accentPressed": (("8F5F12", 1), ("B07C22", 1)),
        "onAccent":      (("FFF8E8", 1), ("2C2718", 1)),
        "hairline":      (("2C2718", 0.12), ("F5EEDC", 0.14)),
        "cellEmpty":     (("2C2718", 0.05), ("F5EEDC", 0.06)),
        "textSecondary": (("2C2718", 0.64), ("F0E7D0", 0.60)),
    ]

    /// Tokens the direction needs that the palette tables do not name.
    static let derived = [
        "tileEdge", "danger",
        "shadowTile", "shadowCard", "shadowButton", "shadowSelected",
        "topHighlight",
    ]

    static var allTokens: [String] { palette.keys.sorted() + derived }

    @Test("Every semantic token has a color set")
    func everyTokenResolves() {
        for token in Self.allTokens {
            let dir = StyleRepo.colorsDir.appendingPathComponent("\(token).colorset/Contents.json")
            #expect(FileManager.default.fileExists(atPath: dir.path), "no color set for \(token)")
        }
    }

    @Test("Every color set carries both an Any and a Dark appearance")
    func bothAppearancesExist() throws {
        for token in Self.allTokens {
            let entries = try Self.entries(token)
            #expect(entries.any != nil, "\(token) has no Any appearance")
            #expect(entries.dark != nil, "\(token) has no Dark appearance")
        }
    }

    @Test("Palette color sets match the pinned tables exactly")
    func valuesMatchTheTables() throws {
        for (token, expected) in Self.palette {
            let entries = try Self.entries(token)
            #expect(entries.any.map(Self.describe) == Self.describe(expected.light), "\(token) light")
            #expect(entries.dark.map(Self.describe) == Self.describe(expected.dark), "\(token) dark")
        }
    }

    @Test("No color set is defined that nothing names")
    func noOrphanColorSets() throws {
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: StyleRepo.colorsDir.path)
            .filter { $0.hasSuffix(".colorset") }
            .map { String($0.dropLast(".colorset".count)) }
        #expect(Set(onDisk) == Set(Self.allTokens), "catalog holds \(Set(onDisk).symmetricDifference(Set(Self.allTokens)).sorted())")
    }

    // MARK: - Helpers

    typealias Components = (hex: String, alpha: Double)

    static func describe(_ c: Components) -> String {
        "\(c.hex.uppercased())@\(String(format: "%.3f", c.alpha))"
    }

    static func entries(_ token: String) throws -> (any: Components?, dark: Components?) {
        let url = StyleRepo.colorsDir.appendingPathComponent("\(token).colorset/Contents.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let colors = json?["colors"] as? [[String: Any]] ?? []

        func parse(_ entry: [String: Any]) -> Components? {
            guard let color = entry["color"] as? [String: Any],
                  let comps = color["components"] as? [String: String],
                  let r = comps["red"], let g = comps["green"], let b = comps["blue"],
                  let a = comps["alpha"].flatMap(Double.init)
            else { return nil }
            let hex = [r, g, b].map { $0.replacingOccurrences(of: "0x", with: "").uppercased() }.joined()
            return (hex, a)
        }

        let dark = colors.first { entry in
            (entry["appearances"] as? [[String: Any]])?
                .contains { $0["value"] as? String == "dark" } ?? false
        }
        let anyAppearance = colors.first { $0["appearances"] == nil }

        return (anyAppearance.flatMap(parse), dark.flatMap(parse))
    }
}
