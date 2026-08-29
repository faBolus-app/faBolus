import Testing
import Foundation

/// Pins that both widgets import faBolusCore and call `GlucoseRange.classify` with no local 70/180/250
/// threshold literals. A widget-local band would drift from the dose-path classifier.
struct WidgetCoreDelegationGuardTests {

    /// The two widget source files. `faBolusAppTests` cannot link the widget extension, so a source scan is the proof.
    private static let targetFiles = [
        "ios/faBolusWidgets/GlucoseWidget.swift",
        "ios/faBolusWidgets/StatusWidget.swift"
    ]

    /// Band-boundary values `GlucoseRange.classify` owns. A widget file containing one as a bare numeric
    /// literal outside a comment would indicate a local reimplementation of the classification boundary.
    private static let forbiddenThresholdLiterals = ["70", "180", "250"]

    /// Resolve the repo root by walking up from `#filePath` until `project.yml` (a stable, always-checked-in
    /// repo-root marker) is found. Same walk-up technique as `BandDriftGuardTests.repoRootURL()`.
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

    /// Strip `//`-style line comments before scanning for the forbidden threshold literals — the file's
    /// own doc comments legitimately cite "70–180" in prose describing the in-range band visually drawn
    /// via the ALREADY-mirrored, already-tested `WidgetGlucoseThresholds` constants (see
    /// `WidgetGlucoseThresholdsMirrorTests`), so an unstripped scan would false-positive on that prose.
    /// Same technique as `BandDriftGuardTests.stripLineComments`.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let idx = line.range(of: "//") { return String(line[..<idx.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    /// (a) both widget files reference `GlucoseRange.classify` and `import faBolusCore`; (b) neither
    /// contains a hardcoded glucose mg/dL threshold literal outside a comment; a `filesScanned > 0` guard
    /// so a broken path resolution fails loudly instead of vacuously passing.
    @Test func bothWidgetsDelegateGlucoseBandClassificationToCore() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        var filesScanned = 0
        var missingImport: [String] = []
        var missingClassifyCall: [String] = []
        var thresholdLiteralHits: [String] = []

        for relPath in Self.targetFiles {
            let url = repoRoot.appendingPathComponent(relPath)
            let raw = try String(contentsOf: url, encoding: .utf8)
            filesScanned += 1

            if !raw.contains("import faBolusCore") {
                missingImport.append(relPath)
            }
            if !raw.contains("GlucoseRange.classify") {
                missingClassifyCall.append(relPath)
            }

            let stripped = Self.stripLineComments(raw)
            for literal in Self.forbiddenThresholdLiterals where stripped.contains(literal) {
                thresholdLiteralHits.append("\(relPath) contains raw threshold literal '\(literal)' outside a comment")
            }
        }

        #expect(
            missingImport.isEmpty,
            "widget file(s) missing 'import faBolusCore' — CX-A-06 Core delegation regressed: \(missingImport)")
        #expect(
            missingClassifyCall.isEmpty,
            "widget file(s) no longer call GlucoseRange.classify — CX-A-06 Core delegation regressed: \(missingClassifyCall)"
        )
        #expect(
            thresholdLiteralHits.isEmpty,
            "widget file(s) reintroduced a local glucose threshold literal (CX-A-06 drift):\n\(thresholdLiteralHits.joined(separator: "\n"))"
        )
        #expect(
            filesScanned > 0,
            "expected to scan the 2 widget files under \(repoRoot.path) — path resolution broke (would otherwise pass vacuously)"
        )
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors
    /// `BandDriftGuardTests.fileResolutionActuallyFoundTheRepoRoot`).
    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(
            Self.repoRootURL() != nil,
            "guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
