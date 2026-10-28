import Foundation
import Testing

/// Checks the String Catalog itself, read from the source tree: a translation
/// with a different placeholder than its English string compiles, and then
/// crashes or prints garbage when that string is shown.
struct LocalizationTests {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ThermoTune/Localizable.xcstrings")

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable { let value: String }
                let stringUnit: Unit?
            }
            let localizations: [String: Localization]?
            let shouldTranslate: Bool?
        }
        let strings: [String: Entry]
    }

    /// Placeholder types in argument order, with positional ones (`%2$@`) put
    /// back in their position.
    static func placeholders(_ string: String) -> [String] {
        let pattern = #/%(?:(\d+)\$)?(lld|ld|d|@|\.?\d*f)/#
        var positional: [(Int, String)] = []
        var next = 1
        for match in string.matches(of: pattern) {
            let type = String(match.output.2)
            if let position = match.output.1.flatMap({ Int($0) }) {
                positional.append((position, type))
            } else {
                positional.append((next, type))
                next += 1
            }
        }
        return positional.sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test func placeholderParsing() {
        #expect(Self.placeholders("Now %@ → %lld RPM") == ["@", "lld"])
        #expect(Self.placeholders("%2$@ vor %1$lld") == ["lld", "@"])
    }

    @Test func everyTranslationKeepsItsPlaceholders() throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Self.catalogURL))
        #expect(catalog.strings.count > 100)
        for (key, entry) in catalog.strings where entry.shouldTranslate != false {
            let english = entry.localizations?["en"]?.stringUnit?.value ?? key
            guard let german = entry.localizations?["de"]?.stringUnit?.value else {
                Issue.record("No German for \"\(key)\"")
                continue
            }
            #expect(Self.placeholders(german) == Self.placeholders(english), "\"\(key)\" → \"\(german)\"")
        }
    }
}
