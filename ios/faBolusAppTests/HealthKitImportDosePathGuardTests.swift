import Testing
import Foundation

/// Imported HealthKit history is display-only and must never enter the signed dose path
/// (`BolusMath`, `GlucoseArbiter`, `TandemBackend`, `PumpTransport`).
struct HealthKitImportDosePathGuardTests {

    /// Resolve the repo root by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/HealthKitImportDosePathGuardTests.swift`) — same technique as
    /// `LoopInsightsExclusionGuardTests.appDirURL()`.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Packages/faBolusCore/Sources/faBolusCore/BolusMath.swift")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// The dose-path files this guard scans — the same four named in the PLAN's `<prohibitions>` and
    /// `<verification>` (BolusMath, GlucoseArbiter, TandemBackend, PumpTransport).
    private static let doseSourcePathRelativePaths: [String] = [
        "Packages/faBolusCore/Sources/faBolusCore/BolusMath.swift",
        "Packages/faBolusCore/Sources/faBolusCore/GlucoseArbiter.swift",
        "ios/faBolus/Data/TandemBackend.swift",
        "ios/faBolus/Data/Tandem/PumpTransport.swift",
    ]

    /// The forbidden HealthKit-import/export symbols. Held as plain string constants — this scan
    /// targets the dose-path SOURCE files below, never this test file itself.
    private static let forbiddenSymbols = ["HealthKitHistoryImporter", "HealthKitExporter"]

    @Test func doseSourcePathFilesResolveAndAreNonTrivial() throws {
        let root = try #require(Self.repoRootURL(),
                                "could not resolve the repo root from #filePath=\(#filePath)")
        for relativePath in Self.doseSourcePathRelativePaths {
            let url = root.appendingPathComponent(relativePath)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                      "could not resolve \(relativePath) — path resolution likely broke")
            #expect(source.count > 200, "\(relativePath) resolved implausibly short — path resolution likely broke")
        }
    }

    @Test func doseSourcePathFilesContainNoHealthKitImportExportSymbols() throws {
        let root = try #require(Self.repoRootURL(),
                                "could not resolve the repo root from #filePath=\(#filePath)")
        for relativePath in Self.doseSourcePathRelativePaths {
            let url = root.appendingPathComponent(relativePath)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                      "could not resolve \(relativePath) — path resolution likely broke")
            for symbol in Self.forbiddenSymbols {
                #expect(!source.contains(symbol),
                        "D-05 violated — forbidden HealthKit import/export symbol '\(symbol)' found in \(relativePath). Imported HealthKit history must land ONLY in GlucoseHistoryStore.ingest*, never the signed dose path.")
            }
        }
    }
}
