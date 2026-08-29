import Testing
import Foundation
@testable import faBolus

/// **§13 collision guard.** `BolusSuccessBanner.swift`'s success checkmark must use
/// plain `Color.green`, NEVER `AppTheme.inRange` — that token is the §13-locked clinical "in range"
/// glucose-band color (`Packages/faBolusDesign/Sources/faBolusDesign/AppTheme.swift`); reusing it for
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

    /// Strip `//`-style line comments (including `///` doc comments) — this file's OWN doc comments
    /// legitimately name `AppTheme.inRange` in prose (explaining what must never appear in CODE), so an
    /// unstripped scan of `checkmarkUsesPlainColorGreen`'s negative-assertion twin would false-positive
    /// on that prose. Same technique as `BandDriftGuardTests.stripLineComments`.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let idx = line.range(of: "//") { return String(line[..<idx.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func bannerSource() throws -> String {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent("ios/faBolus/Views/BolusSuccessBanner.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return Self.stripLineComments(raw)
    }

    @Test func checkmarkUsesPlainColorGreen() throws {
        let source = try Self.bannerSource()
        #expect(
            source.contains("Color.green"),
            "BolusSuccessBanner.swift's checkmark must use plain Color.green (outside comments)")
    }

    @Test func noReferenceToClinicalInRangeBandToken() throws {
        let source = try Self.bannerSource()
        #expect(
            !source.contains("AppTheme.inRange"),
            "BolusSuccessBanner.swift must not reference the §13-locked AppTheme.inRange band token in code (semantic collision)"
        )
    }

    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(
            Self.repoRootURL() != nil,
            "drift-guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
