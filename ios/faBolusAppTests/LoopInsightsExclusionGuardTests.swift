import Testing
import Foundation
@testable import faBolus

/// D-14 (09.18a): LoopInsights is NEVER vendored as a whole dir — only eight benign, DOSE-SAFE
/// files are cherry-picked (the endo-report PDF pair, caffeine tracker pair, alcohol tracker
/// pair, and caregiver-digest pair). Every other file in the upstream LoopInsights dirs is
/// EXCLUDED: the Coordinator, all AI/Chat/advisor/suggestion surfaces, the analyzers, the
/// importers, the background monitors, and the excluded models. A leak of ANY excluded file
/// re-arms the binding no-novel-medical-advice violation and inflates the §13 gate (D-14 /
/// RESEARCH Pitfall 2).
///
/// This guard source-scans the compiled app tree (`ios/faBolus`) and asserts no file whose
/// basename is on the excluded denylist is present. It is green TODAY (only SiteAtlas is
/// vendored this slice — no LoopInsights file exists under `ios/faBolus` yet) and stays green
/// through 09.18d as long as ONLY the eight benign INCLUDE files are added: those eight
/// basenames are deliberately absent from `deniedBasenames`, so 09.18d can add them without
/// tripping this guard.
///
/// The denylist is the exhaustive upstream LoopInsights inventory
/// (`/Users/zgranowitz/Code/zgranowitz/LoopPowerPack-Loop/Loop/{Services,Views,Models,Managers}/LoopInsights/`,
/// RESEARCH §4) MINUS the eight benign INCLUDE files (D-14).
///
/// Mirrors `SettingsReachabilityGuardTests`' recursive `allSwiftFiles(under:)` enumerator (skips
/// `.build`/`DerivedData`/`*Tests` dirs) + the `#filePath`-rooted walk-up resolve idiom.
struct LoopInsightsExclusionGuardTests {
    /// EXCLUDED LoopInsights source-file basenames (D-14 / RESEARCH §4). The eight benign INCLUDE
    /// files (ReportGenerator, EndoReportView, CaffeineTracker, CaffeineLogView, AlcoholTracker,
    /// AlcoholLogView, CaregiverDigestService, CaregiverDigestView) are intentionally NOT here —
    /// 09.18d adds those.
    static let deniedBasenames: Set<String> = [
        // Managers/LoopInsights
        "LoopInsights_BackgroundMonitor.swift",
        "LoopInsights_Coordinator.swift",
        // Services/LoopInsights (excluded)
        "LoopInsights_AIAnalysis.swift",
        "LoopInsights_AIServiceAdapter.swift",
        "LoopInsights_AdvancedAnalyzers.swift",
        "LoopInsights_BackfillDetector.swift",
        "LoopInsights_BehaviorInsightsAnalyzer.swift",
        "LoopInsights_ChatHistoryStore.swift",
        "LoopInsights_DataAggregator.swift",
        "LoopInsights_FoodResponseAnalyzer.swift",
        "LoopInsights_GlucoseUnitContext.swift",
        "LoopInsights_HealthKitManager.swift",
        "LoopInsights_MFPImporter.swift",
        "LoopInsights_MealDebriefService.swift",
        "LoopInsights_NightscoutImporter.swift",
        "LoopInsights_PreMealAdvisorService.swift",
        "LoopInsights_SecureStorage.swift",
        "LoopInsights_SuggestionStore.swift",
        "LoopInsights_TestDataProvider.swift",
        "LoopInsights_VoiceService.swift",
        // Views/LoopInsights (excluded)
        "LoopInsights_AGPChartView.swift",
        "LoopInsights_BehaviorInsightsView.swift",
        "LoopInsights_ChatHistoryView.swift",
        "LoopInsights_ChatView.swift",
        "LoopInsights_DashboardView.swift",
        "LoopInsights_MealDebriefCard.swift",
        "LoopInsights_MealInsightsView.swift",
        "LoopInsights_MonitorSettingsView.swift",
        "LoopInsights_PreMealAdvisorCard.swift",
        "LoopInsights_SettingsView.swift",
        "LoopInsights_SignalGapHistoryView.swift",
        "LoopInsights_SubstackPromo.swift",
        "LoopInsights_SuggestionDetailView.swift",
        "LoopInsights_SuggestionHistoryView.swift",
        "LoopInsights_TrendsInsightsView.swift",
        // Models/LoopInsights (excluded — benign structs are re-created, not bulk-vendored)
        "LoopInsights_MFPModels.swift",
        "LoopInsights_MealDebriefModels.swift",
        "LoopInsights_Models.swift",
        "LoopInsights_Phase5Models.swift",
        "LoopInsights_SuggestionRecord.swift",
    ]

    /// The eight benign INCLUDE files (D-14) that 09.18d may add — must NOT be on the denylist.
    /// Asserted below so a future edit can't silently move a benign file onto the denylist and
    /// block 09.18d.
    static let benignIncludeBasenames: Set<String> = [
        "LoopInsights_ReportGenerator.swift",
        "LoopInsights_EndoReportView.swift",
        "LoopInsights_CaffeineTracker.swift",
        "LoopInsights_CaffeineLogView.swift",
        "LoopInsights_AlcoholTracker.swift",
        "LoopInsights_AlcoholLogView.swift",
        "LoopInsights_CaregiverDigestService.swift",
        "LoopInsights_CaregiverDigestView.swift",
    ]

    /// Resolve `ios/faBolus` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/LoopInsightsExclusionGuardTests.swift`) — same technique as
    /// `SettingsReachabilityGuardTests.viewsDirURL()`.
    private static func appDirURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("ios/faBolus")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Recursively enumerate every `.swift` under `root`, skipping build artifacts + test-target
    /// dirs. Verbatim copy of `SettingsReachabilityGuardTests.allSwiftFiles(under:)` for parity —
    /// kept private so this suite has no cross-file test-target dependency.
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let skipDirNames: Set<String> = [".build", "DerivedData", "Pods", ".git", "node_modules"]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipDirNames.contains(name) || name.hasSuffix("Tests") {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "swift" { results.append(url) }
        }
        return results
    }

    // MARK: - D-14: no excluded LoopInsights file is compiled under ios/faBolus

    @Test func noExcludedLoopInsightsFileIsCompiled() throws {
        guard let appDir = Self.appDirURL() else {
            Issue.record("could not resolve ios/faBolus from #filePath=\(#filePath)")
            return
        }
        let files = Self.allSwiftFiles(under: appDir)
        // A path-resolution bug must fail loudly, not pass vacuously (mirrors
        // SettingsReachabilityGuardTests' !files.isEmpty guard).
        #expect(!files.isEmpty, "path resolution broke — found zero ios/faBolus/**/*.swift files")

        for url in files {
            let basename = url.lastPathComponent
            #expect(!Self.deniedBasenames.contains(basename),
                    "D-14 violated — excluded LoopInsights file '\(basename)' is compiled at \(url.path). Excluded files re-arm the no-novel-medical-advice violation and inflate the §13 gate; only the eight benign INCLUDE files may be vendored.")
        }
    }

    // MARK: - The eight benign INCLUDE files must never be on the denylist

    @Test func benignIncludeFilesAreNotDenied() {
        for basename in Self.benignIncludeBasenames {
            #expect(!Self.deniedBasenames.contains(basename),
                    "\(basename) is a benign D-14 INCLUDE file (09.18d scope) and must NOT be on the exclusion denylist — otherwise this guard would block 09.18d from vendoring it.")
        }
    }
}
