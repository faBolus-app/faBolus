import Testing
import Foundation
@testable import faBolus

/// The §8 L7 "never bolus / never voice-write" invariant (999.2, D-07): the ONLY intents ever
/// registered as Siri voice phrases (`FaBolusShortcuts: AppShortcutsProvider`) are the five read-only
/// status queries. No write intent (`SetTempRateIntent`, `ActivateProfileIntent`, `Set*Mode`) and no
/// bolus/carb intent may ever get a Siri phrase — a voice-triggered pump write or a voice bolus is
/// explicitly out of scope by design.
///
/// `AppShortcut` (Apple's App Intents framework) exposes NO public getters post-construction — only
/// initializers — so `FaBolusShortcuts.appShortcuts[i].shortTitle` cannot be read back at runtime. This
/// suite therefore combines a runtime check (the array's `count`, which IS observable) with a
/// `#filePath`-rooted SOURCE SCAN of `StatusIntents.swift` for the registered `shortTitle:` literals —
/// the same technique `LiveActivityBoundaryTests`/`RescueCarbGuardTests` use for a boundary invariant
/// that isn't expressible purely through a runtime API. Together, `count == 5` (catches an ADDITION)
/// plus the exact-title-set match (catches a SWAP — removing a read-only entry and adding a write entry
/// while holding the count at 5) close both ways this invariant could silently regress.
///
/// **Fault-injection performed to prove this guard bites (2026-08-13, reverted before commit):**
/// temporarily added a 6th `AppShortcut(intent: GlucoseQueryIntent(), phrases: [...], shortTitle:
/// "Bogus Sixth", ...)` to `FaBolusShortcuts.appShortcuts` in `StatusIntents.swift`. Result: both
/// `exactlyFiveReadOnlyStatusQueriesAreRegisteredAsSiriPhrases` (count became 6) and
/// `theRegisteredShortcutTitlesAreExactlyTheFiveReadOnlyQueries` (title set gained "Bogus Sixth") went
/// RED as expected. The injected shortcut was then removed — no trace remains in `StatusIntents.swift`
/// or this file.
struct ShortcutsL7BoundaryTests {

    /// The exact five read-only status-query shortTitles `StatusIntents.swift` registers today
    /// (`StatusIntents.swift:146-177`). A machine-checked list, not prose — mirrors
    /// `SettingsCatalog.commandAdjacentFlags`'s greppable-invariant idiom.
    static let expectedShortTitles: Set<String> = [
        "Glucose", "Insulin on Board", "Pump Status", "Last Bolus", "Alerts",
    ]

    // MARK: - Runtime check (catches an ADDITION)

    /// The load-bearing guard: registering ANY write intent (`SetTempRateIntent`,
    /// `ActivateProfileIntent`, `Set*Mode`) or a bolus/carb intent as an `AppShortcut` raises this
    /// count and fails the suite.
    @Test func exactlyFiveReadOnlyStatusQueriesAreRegisteredAsSiriPhrases() {
        #expect(FaBolusShortcuts.appShortcuts.count == 5,
                "§8 L7 violated — FaBolusShortcuts.appShortcuts must register EXACTLY the 5 read-only status queries")
    }

    // MARK: - Source scan (catches a SWAP — count stays 5 but a title changed)

    /// Resolve `ios/faBolus/Intents/StatusIntents.swift` from `#filePath`
    /// (`<root>/ios/faBolusAppTests/ShortcutsL7BoundaryTests.swift`), walking up to the repo root —
    /// same technique as `LiveActivityBoundaryTests.intentsFileURL()` / `RescueCarbGuardTests.scanRoots()`.
    private static func statusIntentsFileURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("ios/faBolus/Intents/StatusIntents.swift")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Extract every `shortTitle: "..."` string-literal argument from the source text (the file has no
    /// other `shortTitle:` call sites, so a plain regex over the whole file is sufficient — no need to
    /// isolate the `appShortcuts` computed property body specifically).
    private static func extractShortTitles(from source: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"shortTitle:\s*"([^"]*)""#) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: range)
        return Set(matches.compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        })
    }

    @Test func theRegisteredShortcutTitlesAreExactlyTheFiveReadOnlyQueries() throws {
        guard let url = Self.statusIntentsFileURL() else {
            Issue.record("could not resolve ios/faBolus/Intents/StatusIntents.swift from #filePath=\(#filePath)")
            return
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let titles = Self.extractShortTitles(from: source)
        #expect(titles == Self.expectedShortTitles,
                "§8 L7 violated — StatusIntents.swift's registered shortTitles are \(titles.sorted()), expected exactly \(Self.expectedShortTitles.sorted())")
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors `LiveActivityBoundaryTests`'
    /// own `fileResolutionActuallyFoundTheIntentsFile` guard).
    @Test func fileResolutionActuallyFoundStatusIntentsFile() {
        #expect(Self.statusIntentsFileURL() != nil,
                "boundary test could not locate ios/faBolus/Intents/StatusIntents.swift — path resolution broke (#filePath=\(#filePath))")
    }
}
