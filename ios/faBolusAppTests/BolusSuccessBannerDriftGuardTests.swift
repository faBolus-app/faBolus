import Testing
import Foundation
@testable import faBolus

/// **Phase 09.4 T-09.4-01/§13 collision guard.** `BolusSuccessBanner.swift`'s success checkmark must use
/// plain `Color.green`, NEVER `AppTheme.inRange` — that token is the §13-locked clinical "in range"
/// glucose-band color (`Packages/faBolusDesign/Sources/faBolusDesign/AppTheme.swift:15`); reusing it for
/// an unrelated bolus-success affordance would create a semantic collision the band drift-guard
/// (`BandDriftGuardTests`) does not (and should not) catch, since this isn't a band-classification call
/// site. Modeled on `BandDriftGuardTests`'s repo-root-walk + source-scan idiom.
struct BolusSuccessBannerDriftGuardTests {

    /// Resolve the repo root by walking up from `#filePath` until `project.yml` is found (same
    /// technique as `BandDriftGuardTests.repoRootURL()`).
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

    private static func bannerSource() throws -> String {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent("ios/faBolus/Views/BolusSuccessBanner.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func checkmarkUsesPlainColorGreen() throws {
        let source = try Self.bannerSource()
        #expect(source.contains("Color.green"),
                "BolusSuccessBanner.swift's checkmark must use plain Color.green")
    }

    @Test func noReferenceToClinicalInRangeBandToken() throws {
        let source = try Self.bannerSource()
        #expect(!source.contains("AppTheme.inRange"),
                "BolusSuccessBanner.swift must not reference the §13-locked AppTheme.inRange band token (semantic collision)")
    }

    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(Self.repoRootURL() != nil,
                "drift-guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
