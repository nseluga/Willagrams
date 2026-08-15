import CoreText
import Foundation
import Testing

/// Proves the five bundled faces really load.
///
/// The failure this exists for is silent: an unregistered or misnamed face
/// falls back to San Francisco, which looks like a deliberate choice rather
/// than a bug and would ship unnoticed. So every assertion here compares the
/// *resolved* font against the bundled family, never just "a font came back".
@Suite("Brand fonts")
struct BrandFontsTests {

    /// PostScript name → the family CoreText resolves it into.
    ///
    /// The four sans cuts ship with split `name` table families
    /// (`Instrument Sans Medium` and friends) but CoreText reads the
    /// typographic family and collapses them back to one `Instrument Sans`.
    /// The PostScript name is what keeps the four distinct, which is why
    /// `Font.brand` addresses faces that way.
    static let expected: [String: String] = [
        "InstrumentSans-Regular":  "Instrument Sans",
        "InstrumentSans-Medium":   "Instrument Sans",
        "InstrumentSans-SemiBold": "Instrument Sans",
        "InstrumentSans-Bold":     "Instrument Sans",
        "FragmentMono-Regular":    "Fragment Mono",
    ]

    /// Registers every bundled TTF once for the whole suite.
    static let registered: Set<String> = {
        var ok: Set<String> = []
        for name in expected.keys {
            let url = StyleRepo.fontsDir.appendingPathComponent("\(name).ttf")
            guard let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let font = CGFont(provider)
            else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterGraphicsFont(font, &error) {
                ok.insert(name)
            } else if let e = error?.takeRetainedValue(),
                      CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue {
                ok.insert(name)
            }
        }
        return ok
    }()

    @Test("All five TTFs plus the licence ship in Resources/Branding/Fonts")
    func filesArePresent() throws {
        for name in Self.expected.keys {
            let url = StyleRepo.fontsDir.appendingPathComponent("\(name).ttf")
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(name).ttf")
        }
        #expect(FileManager.default.fileExists(atPath: StyleRepo.fontsDir.appendingPathComponent("OFL.txt").path))
    }

    @Test("Each bundled TTF is a static cut, not the variable font")
    func facesAreStatic() throws {
        for name in Self.expected.keys {
            let url = StyleRepo.fontsDir.appendingPathComponent("\(name).ttf")
            let data = try Data(contentsOf: url)
            // 'fvar' is the variable-font axis table. Its presence means we
            // grabbed InstrumentSans[wdth,wght].ttf from the wrong source, and
            // per-weight PostScript lookups would all resolve to one face.
            #expect(!Self.containsTable("fvar", in: data), "\(name).ttf is a variable font")
        }
    }

    @Test("Every face resolves to its bundled family, not the system font")
    func facesResolve() throws {
        let systemFamily = CTFontCopyFamilyName(CTFontCreateUIFontForLanguage(.system, 17, nil)!) as String

        for (postScript, family) in Self.expected {
            #expect(Self.registered.contains(postScript), "\(postScript) failed to register")

            let font = CTFontCreateWithName(postScript as CFString, 17, nil)
            let resolvedFamily = CTFontCopyFamilyName(font) as String
            let resolvedPostScript = CTFontCopyPostScriptName(font) as String

            #expect(resolvedFamily == family, "\(postScript) resolved to family \(resolvedFamily)")
            #expect(resolvedPostScript == postScript, "\(postScript) resolved to \(resolvedPostScript)")
            #expect(resolvedFamily != systemFamily, "\(postScript) fell back to the system font")
        }
    }

    @Test("The resolution check would catch a missing face")
    func checkCatchesAFallback() {
        // CoreText answers an unknown PostScript name with the system font
        // rather than nil — which is exactly why facesResolve compares names.
        let font = CTFontCreateWithName("InstrumentSans-NotAFace" as CFString, 17, nil)
        #expect((CTFontCopyPostScriptName(font) as String) != "InstrumentSans-NotAFace")
    }

    @Test("BrandFonts.swift asks for exactly the five bundled PostScript names")
    func sourceNamesMatchTheFiles() throws {
        let source = try StyleRepo.source("BrandFonts.swift")
        let declared = Set(StyleRepo.matches(#"case \w+\s*=\s*"([A-Za-z]+-[A-Za-z]+)""#, in: source))
        #expect(declared == Set(Self.expected.keys), "BrandFonts declares \(declared.sorted())")
    }

    @Test("register() is wired into app launch")
    func registeredAtLaunch() throws {
        let app = try String(
            contentsOf: StyleRepo.root.appendingPathComponent("Willagrams/App/WillagramsApp.swift"),
            encoding: .utf8
        )
        #expect(StyleRepo.strippingComments(app).contains("BrandFonts.registerOnce()"))
    }

    /// True if the TrueType table directory contains `tag`.
    static func containsTable(_ tag: String, in data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return false }
        let count = Int(bytes[4]) << 8 | Int(bytes[5])
        let want = Array(tag.utf8)
        for i in 0..<count {
            let offset = 12 + 16 * i
            guard offset + 4 <= bytes.count else { return false }
            if Array(bytes[offset..<(offset + 4)]) == want { return true }
        }
        return false
    }
}
