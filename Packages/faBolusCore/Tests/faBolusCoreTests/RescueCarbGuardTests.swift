import Testing
import Foundation

/// Permanent guard: faBolus must never surface a suggested rescue-carbohydrate amount for treating a low.
/// Scans shipping surfaces for rescue-carb-amount APIs or copy; ordinary meal-bolus carb entry must not trip it.
struct RescueCarbGuardTests {

    /// Case-insensitive regexes that denote a rescue-carb-*amount* feature (identifier or copy). Separators
    /// (`\s`, `_`, `-`) are tolerated so `rescueCarb`, `rescue_carb`, `rescue-carb`, and "rescue carbs" all
    /// trip the same guard.
    private static let bannedPatterns = [
        #"rescue[\s_\-]*carb"#,
        #"carbs?[\s_\-]*(to|for)[\s_\-]*treat"#,
        #"treat(ing)?[\s_\-]*(a[\s_\-]*)?(low|hypo)[\s_\-]*with[\s_\-]*carb"#,
        #"(low|hypo)[\s_\-]*treatment[\s_\-]*carb"#,
        #"carb[\s_\-]*(for|to)[\s_\-]*(treat[\s_\-]*)?(a[\s_\-]*)?(low|hypo)"#,
        #"grams?[\s_\-]*(of[\s_\-]*carbs?[\s_\-]*)?to[\s_\-]*treat"#,
    ]

    /// Resolve the directories to scan from `#filePath`
    /// (`<root>/Packages/faBolusCore/Tests/faBolusCoreTests/RescueCarbGuardTests.swift`). Walks up to the
    /// repo root (the ancestor containing both `ios/faBolus` and `Packages/faBolusCore/Sources`).
    private func scanRoots() -> (dirs: [URL], sawApp: Bool) {
        let fm = FileManager.default
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var probe = here
        for _ in 0..<8 {
            let ios = probe.appendingPathComponent("ios")   // all app targets, not just ios/faBolus
            let core = probe.appendingPathComponent("Packages/faBolusCore/Sources")
            if fm.fileExists(atPath: ios.path), fm.fileExists(atPath: core.path) {
                var dirs = [ios, core]
                let shared = probe.appendingPathComponent("Shared")
                if fm.fileExists(atPath: shared.path) { dirs.append(shared) }
                return (dirs, true)
            }
            probe = probe.deletingLastPathComponent()
        }
        // Fallback (package consumed standalone): scan only faBolusCore/Sources, which is two levels up
        // from this test file's directory (…/Tests/faBolusCoreTests → …/faBolusCore) then `/Sources`.
        let coreSources = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        return ([coreSources], false)
    }

    @Test func noRescueCarbAmountApiOrString() throws {
        let fm = FileManager.default
        let regexes = try Self.bannedPatterns.map {
            try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        let (dirs, sawApp) = scanRoots()
        var scanned = 0
        var violations: [String] = []
        for base in dirs {
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                // This guard file necessarily contains the banned patterns — don't flag itself.
                if url.lastPathComponent == "RescueCarbGuardTests.swift" { continue }
                if url.path.contains("Tests") { continue }   // shipping surfaces only — a test mentioning the banned concept is not a surfaced suggestion
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                let range = NSRange(text.startIndex..., in: text)
                for rx in regexes where rx.firstMatch(in: text, options: [], range: range) != nil {
                    violations.append("\(url.lastPathComponent) matches /\(rx.pattern)/")
                }
            }
        }
        // A path-resolution bug must fail loudly, not pass vacuously.
        #expect(scanned > 0, "rescue-carb guard scanned no files — path resolution broke (#filePath=\(#filePath))")
        #expect(sawApp, "rescue-carb guard could not locate ios/faBolus — it must scan the shipping app, not only faBolusCore")
        let joined = violations.joined(separator: "; ")
        #expect(violations.isEmpty,
                "P16 §8-H: a rescue-carb-amount API/string was reintroduced (do NOT implement, do NOT reintroduce): \(joined)")
    }
}
