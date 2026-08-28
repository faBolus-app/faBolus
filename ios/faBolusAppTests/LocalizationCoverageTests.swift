import Testing
import Foundation
@testable import faBolus

/// Pins that remote-bolus confirm and bolus-success copy is routed through Localizable.xcstrings. Dose-path strings that bypass the catalog cannot be localized and can drift from the English keys.
struct LocalizationCoverageTests {

    /// Resolve the repo root by walking up from `#filePath` until `project.yml` is found (same
    /// technique as `BandDriftGuardTests`/`BolusSuccessBannerDriftGuardTests.repoRootURL()`).
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("project.yml")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func catalog() throws -> [String: Any] {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent("ios/faBolus/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(json, "Localizable.xcstrings did not parse as a JSON object")
    }

    /// The resolved English display value for `key` — either the explicit `localizations.en` value
    /// (when present, for keys the catalog editor had to disambiguate multi-placeholder templates for),
    /// or the key itself (an xcstrings entry with no override, e.g. `{}`, uses the key as its own
    /// `sourceLanguage` value — the convention this repo's existing `"%@ mg/dL"`-style keys already use).
    private static func englishValue(forKey key: String, in strings: [String: Any]) -> String? {
        guard let entry = strings[key] as? [String: Any] else { return nil }
        if let localizations = entry["localizations"] as? [String: Any],
           let en = localizations["en"] as? [String: Any],
           let stringUnit = en["stringUnit"] as? [String: Any],
           let value = stringUnit["value"] as? String {
            return value
        }
        return key
    }

    /// Catalog-routing targets: remote-bolus confirm copy plus BolusSuccessBanner delivered-amount and combo templates.
    private static let expectedKeys: [String: String] = [
        "Remote bolus request": "Remote bolus request",
        "Deliver %@": "Deliver %@",
        "Reject": "Reject",
        "A remote requested %@.": "A remote requested %@.",
        "Carbs: %@.": "Carbs: %@.",
        "No fresh CGM — carbs only, no correction.": "No fresh CGM — carbs only, no correction.",
        "BG: %@ (%@ min ago).": "BG: %1$@ (%2$@ min ago).",
        "BG: %@.": "BG: %@.",
        "IOB: %@.": "IOB: %@.",
        "Confirm to deliver.": "Confirm to deliver.",
        "Bolus delivered": "Bolus delivered",
        "%@ delivered": "%@ delivered",
        "%@ now, %@ total over %@": "%1$@ now, %2$@ total over %3$@",
    ]

    @Test func allSafetyCriticalDoseCopyIsCatalogRouted() throws {
        let root = try Self.catalog()
        let strings = try #require(root["strings"] as? [String: Any], "no top-level \"strings\" object")
        for (key, expectedValue) in Self.expectedKeys {
            let actual = Self.englishValue(forKey: key, in: strings)
            #expect(actual != nil, "Localizable.xcstrings is missing the safety-critical dose-copy key \(key)")
            #expect(actual == expectedValue,
                    "Localizable.xcstrings key \(key) resolved to \(String(describing: actual)), expected \(expectedValue)")
        }
    }

    @Test func sourceLanguageIsEnglish() throws {
        let root = try Self.catalog()
        #expect(root["sourceLanguage"] as? String == "en")
    }
}
