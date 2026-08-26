import Testing
import Foundation

/// CX-A-06 regression guard (17-10, Codex arch review). The Codex review confirmed both widgets ALREADY
/// delegate glucose-band classification to `faBolusCore.GlucoseRange.classify` — there is NO widget-local
/// threshold reimplementation to replace (verified this plan: `import faBolusCore` +
/// `GlucoseRange.classify(g)` at `GlucoseWidget.swift:3,50` and `StatusWidget.swift:3,51`; the widget
/// app-extension target already declares `package: faBolusCore` directly at `project.yml:340`). This suite
/// PINS that already-resolved finding against regression rather than re-fixing it — no widget source was
/// rewritten and no type was moved into `faBolusCore` by this plan (CX-A-04 is deferred to Phase 16).
///
/// Mirrors `BandDriftGuardTests`' idiom (repo-root walk-up to `project.yml`, `//`-line-comment stripping
/// before scanning, a "scanned > 0" loud-not-vacuous guard) rather than inventing a new one.
struct WidgetCoreDelegationGuardTests {

    /// The two widget source files this plan's CX-A-06 finding is about. A behavioral widget test isn't
    /// the right instrument here (Codex, re 17-05): `faBolusAppTests` cannot link the widget extension
    /// target, so a source-scan guard against these exact files is the correct proof.
    private static let targetFiles = [
        "ios/faBolusWidgets/GlucoseWidget.swift",
        "ios/faBolusWidgets/StatusWidget.swift",
    ]

    /// The canonical mg/dL band-boundary values `faBolusCore.GlucoseRange.classify`/`GlucoseThresholds`
    /// owns (70 / 180 / 250 — see `Packages/faBolusCore/Sources/faBolusCore/Models.swift:66-72`). A widget
    /// file containing one of these as a bare numeric literal OUTSIDE a comment would indicate a local
    /// reimplementation of the classification boundary — exactly the drift this finding exists to prevent
    /// — rather than delegation to the one sanctioned Core classifier.
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
        let repoRoot = try #require(Self.repoRootURL(),
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

        #expect(missingImport.isEmpty,
                "widget file(s) missing 'import faBolusCore' — CX-A-06 Core delegation regressed: \(missingImport)")
        #expect(missingClassifyCall.isEmpty,
                "widget file(s) no longer call GlucoseRange.classify — CX-A-06 Core delegation regressed: \(missingClassifyCall)")
        #expect(thresholdLiteralHits.isEmpty,
                "widget file(s) reintroduced a local glucose threshold literal (CX-A-06 drift):\n\(thresholdLiteralHits.joined(separator: "\n"))")
        #expect(filesScanned > 0,
                "expected to scan the 2 widget files under \(repoRoot.path) — path resolution broke (would otherwise pass vacuously)")
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors
    /// `BandDriftGuardTests.fileResolutionActuallyFoundTheRepoRoot`).
    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(Self.repoRootURL() != nil,
                "guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
