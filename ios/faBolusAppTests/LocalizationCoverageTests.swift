import Testing
import Foundation
@testable import faBolus

/// **Phase 17 D2-04.** A regression net for the safety-critical dose copy this plan routes through
/// `Localizable.xcstrings`: `RootTabView`'s remote-bolus confirm alert (title, button, and every
/// `confirmMessage` part) and `BolusSuccessBanner`'s delivered-amount/combo templates. Every string a
/// user could see while confirming or being told the outcome of an insulin delivery must be catalog-
/// routed via `String(localized:)` so it CAN be localized later (adding translations is out of scope
/// here — this test only guards that the English keys exist).
///
/// Parses `Localizable.xcstrings` directly (it's a plain JSON string catalog) rather than going through
/// `Bundle`/`NSLocalizedString`, mirroring `BolusSuccessBannerDriftGuardTests`'s repo-root-walk idiom —
/// no simulator/bundle-loading dependency, so this suite is fast and host-runnable.
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
        let repoRoot = try #require(
            Self.repoRootURL(),
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
            let value = stringUnit["value"] as? String
        {
            return value
        }
        return key
    }

    /// D2-04's exact catalog-routing targets: `RootTabView`'s remote-bolus confirm alert (title, the
    /// two buttons, and every `confirmMessage` part) plus `BolusSuccessBanner`'s delivered-amount and
    /// combo (extended-bolus) templates. Numbered placeholders (`%1$@`, `%2$@`, ...) mirror this
    /// catalog's existing convention for any template with 2+ identical-type substitutions (see the
    /// existing `"%@ · %@ U/hr"`-style entries).
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
        "%@ now, %@ total over %@": "%1$@ now, %2$@ total over %3$@"
    ]

    @Test func allSafetyCriticalDoseCopyIsCatalogRouted() throws {
        let root = try Self.catalog()
        let strings = try #require(root["strings"] as? [String: Any], "no top-level \"strings\" object")
        for (key, expectedValue) in Self.expectedKeys {
            let actual = Self.englishValue(forKey: key, in: strings)
            #expect(actual != nil, "Localizable.xcstrings is missing the safety-critical dose-copy key \(key)")
            #expect(
                actual == expectedValue,
                "Localizable.xcstrings key \(key) resolved to \(String(describing: actual)), expected \(expectedValue)")
        }
    }

    @Test func sourceLanguageIsEnglish() throws {
        let root = try Self.catalog()
        #expect(root["sourceLanguage"] as? String == "en")
    }
}
