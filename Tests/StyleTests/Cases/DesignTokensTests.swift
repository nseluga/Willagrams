import Foundation
import Testing

/// DesignTokens is a frozen contract for board and shell: this lane owns the
/// values, never the key names. A rename would break them at compile time —
/// but only once those lanes exist, so the guard lives here instead.
@Suite("Design tokens")
struct DesignTokensTests {

    /// Every key that existed before the style lane touched the file.
    static let frozen: [String: [String]] = [
        "Palette": ["tileFace", "tileEdge", "tileLetter", "boardSurface",
                    "accent", "danger", "textPrimary", "textSecondary"],
        "Space": ["xs", "s", "m", "l", "xl"],
        "Radius": ["tile", "panel"],
        "Typography": ["tileLetter", "title", "body", "caption"],
        "Motion": ["snapDuration", "dealDuration", "snapThreshold"],
    ]

    /// The keys the direction adds.
    static let added: [String: [String]] = [
        "Palette": ["canvasTop", "canvasBottom", "surface", "ink", "onInk",
                    "onAccent", "accentPressed", "hairline", "cellEmpty"],
        "Radius": ["cell", "pill"],
        "Typography": ["display", "button", "monoLabel"],
        "Motion": ["tileLift"],
    ]

    static let source: String = {
        (try? StyleRepo.source("DesignTokens.swift")).map(StyleRepo.strippingComments) ?? ""
    }()

    /// `enum Name { ... }` body, so a key is only credited to its own group.
    static func group(_ name: String) -> String {
        guard let start = source.range(of: "enum \(name) {") else { return "" }
        var depth = 0
        var out = ""
        for c in source[start.upperBound...] {
            if c == "{" { depth += 1 }
            if c == "}" {
                if depth == 0 { break }
                depth -= 1
            }
            out.append(c)
        }
        return out
    }

    static func declares(_ key: String, in groupName: String) -> Bool {
        StyleRepo.matches(#"(?:static\s+let|static\s+var)\s+(\w+)"#, in: group(groupName)).contains(key)
    }

    @Test("Every pre-existing key still resolves under its original group")
    func frozenKeysSurvive() {
        for (groupName, keys) in Self.frozen {
            for key in keys {
                #expect(Self.declares(key, in: groupName), "DesignTokens.\(groupName).\(key) is gone")
            }
        }
    }

    @Test("The keys the direction needs exist")
    func newKeysExist() {
        for (groupName, keys) in Self.added {
            for key in keys {
                #expect(Self.declares(key, in: groupName), "DesignTokens.\(groupName).\(key) is missing")
            }
        }
    }

    @Test("The key check has teeth — it is scoped to one group and rejects absent keys")
    func keyCheckIsScoped() {
        #expect(!Self.declares("notAKey", in: "Palette"))
        #expect(!Self.declares("tileFace", in: "Space"), "group parsing is leaking across enums")
        #expect(Self.group("Palette").contains("tileFace"))
        #expect(!Self.group("Space").contains("tileFace"))
    }

    @Test("Palette reads from Color Sets, never from literal components")
    func paletteReadsColorSets() {
        let palette = Self.group("Palette")
        #expect(!palette.contains("Color(red:"), "Palette still holds a literal color")

        let named = Set(StyleRepo.matches(#"Color\("(\w+)"\)"#, in: palette))
        #expect(!named.isEmpty)
        for token in named {
            let path = StyleRepo.colorsDir.appendingPathComponent("\(token).colorset/Contents.json")
            #expect(FileManager.default.fileExists(atPath: path.path), "Palette names \(token), which has no color set")
        }
    }

    @Test("Typography uses the bundled families, not the system font")
    func typographyUsesBrandFonts() {
        let typography = Self.group("Typography")
        #expect(!typography.contains("Font.system"), "Typography still falls back to the system font")

        let fontKeys = StyleRepo.matches(#"static let (\w+) = Font\."#, in: typography)
        #expect(fontKeys.count >= 7, "expected the full type ramp, found \(fontKeys)")
        for line in typography.split(separator: "\n") where line.contains("= Font.") {
            #expect(line.contains("Font.brand") || line.contains("Font.mono"), "unbundled face: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    @Test("No style source carries a raw hex literal")
    func noHexOutsideTheCatalog() throws {
        for file in try StyleRepo.styleSources() {
            let stripped = StyleRepo.strippingComments(file.text)
            let hexes = StyleRepo.matches(##"#"?([0-9A-Fa-f]{6})"?"##, in: stripped, group: 1)
            #expect(hexes.isEmpty, "\(file.name) holds hex literal(s) \(hexes)")
            #expect(!stripped.contains("Color(red:"), "\(file.name) holds a literal color")
        }
    }
}
