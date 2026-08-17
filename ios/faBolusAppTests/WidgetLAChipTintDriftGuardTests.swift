import Testing
import Foundation

/// **IN-01 drift-guard (Phase 09.14, D-02).** Proves the `ios/faBolusWidgets` Live Activity pump-chip
/// tints stay wired to `faBolusDesign.AppTheme` and never silently regress to a hardcoded raw color
/// literal. Phase 09.1 (D-03) already removed the three literal-RGB mirrors that used to stand in for
/// `AppTheme.insulin`/`.low`/`.inRange` in `ios/faBolusWidgets/FaBolusWidgetBundle.swift` — the
/// production code this test pins is already correct today; this plan is TEST-ONLY (D-02).
///
/// Modeled on this repo's `BandDriftGuardTests` source-scan idiom (`ios/faBolusAppTests/
/// BandDriftGuardTests.swift`, itself modeled on the Phase-7 MUST-NOT-REACH boundary tests):
/// `repoRootURL()` walks up from `#filePath` to find `project.yml`; `stripLineComments(_:)` strips
/// `//` comments before scanning; `functionSlice`/`balancedSlice` extract a brace-balanced block
/// starting at a signature-line match. `faBolusAppTests` cannot `@testable import faBolusWidgets` —
/// the widget extension is a separate app-extension target (project.yml) that `faBolusAppTests` does
/// not link — so this test reads `FaBolusWidgetBundle.swift`'s raw source text from disk instead of
/// calling into it.
struct WidgetLAChipTintDriftGuardTests {

    // MARK: - Repo enumeration (mirrors BandDriftGuardTests' idiom)

    /// Resolve the repo root by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/WidgetLAChipTintDriftGuardTests.swift`) until `project.yml` — a
    /// stable, always-checked-in repo-root marker — is found.
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

    /// Strip `//`-style line comments so a doc comment that merely NAMES a needle (e.g. this very
    /// file's own header) can never false-positive a scan of production source.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let idx = line.range(of: "//") { return String(line[..<idx.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Balanced-brace forward slice starting at `startIdx` through its matching close — same
    /// technique as `BandDriftGuardTests.balancedSlice`/`NudgeDeliveryBoundaryTests
    /// .balancedFunctionBody`.
    private static func balancedSlice(startingAt startIdx: Int, in lines: [String]) -> String {
        var depth = 0
        var opened = false
        var collected: [String] = []
        for line in lines[startIdx...] {
            collected.append(line)
            for ch in line {
                if ch == "{" { depth += 1; opened = true }
                else if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        return collected.joined(separator: "\n")
    }

    /// Locate a declaration by its signature-line substring and slice it via balanced braces.
    private static func functionSlice(signaturePrefix: String, in lines: [String]) throws -> String {
        guard let startIdx = lines.firstIndex(where: { $0.contains(signaturePrefix) }) else {
            throw SliceError.signatureNotFound(signaturePrefix)
        }
        return Self.balancedSlice(startingAt: startIdx, in: lines)
    }

    private enum SliceError: Error, CustomStringConvertible {
        case signatureNotFound(String)
        var description: String {
            switch self {
            case .signatureNotFound(let sig): return "Signature not found while scanning: \(sig)"
            }
        }
    }

    /// Resolves + strips-of-comments `ios/faBolusWidgets/FaBolusWidgetBundle.swift`'s lines once,
    /// shared by every test below.
    private static func widgetBundleLines() throws -> [String] {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent("ios/faBolusWidgets/FaBolusWidgetBundle.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return Self.stripLineComments(raw).components(separatedBy: "\n")
    }

    // MARK: - Prong 1: per-chip AppTheme reference pin

    /// Every salient pump-chip builder (`reservoirChip` excluded — it has no clinical-band AppTheme
    /// reference today, D-02's own scope note) must still reference `AppTheme` for its clinically
    /// salient tint. NOTE: this is currently the deliberately-WRONG sanity needle (RED step, D-02
    /// task's own required "scan mechanism is not vacuous" check) — `iobChip` is asserted to contain
    /// a nonexistent 'AppTheme.doesNotExist' string, which MUST fail. GREEN swaps this for the real
    /// per-function `AppTheme.*` needle table.
    @Test func salientPumpChipsStillReferenceAppThemeDirectly() throws {
        let lines = try Self.widgetBundleLines()

        let expectations: [(function: String, needles: [String])] = [
            ("iobChip(", ["AppTheme.doesNotExist"]),
        ]

        for expectation in expectations {
            let slice = try Self.functionSlice(signaturePrefix: "static func \(expectation.function)", in: lines)
            for needle in expectation.needles {
                #expect(slice.contains(needle),
                        "\(expectation.function) no longer references '\(needle)' — LA pump-chip tint drifted from AppTheme")
            }
        }
    }

    // MARK: - Prong 2: whole-vocabulary raw-literal ban

    /// From `struct PumpChip {` through the end of the file (nothing follows `chip(for:_:)` in
    /// `FaBolusWidgetBundle.swift`), no raw `Color(red:` literal-RGB constructor may appear — a future
    /// edit swapping an `AppTheme.*` reference for a raw literal must fail this guard.
    @Test func noRawColorLiteralInsideThePumpChipVocabulary() throws {
        let lines = try Self.widgetBundleLines()
        guard let startIdx = lines.firstIndex(where: { $0.contains("struct PumpChip {") }) else {
            Issue.record("could not locate 'struct PumpChip {' in FaBolusWidgetBundle.swift — scan broke")
            return
        }
        let vocabulary = lines[startIdx...].joined(separator: "\n")
        #expect(!vocabulary.contains("Color(red:"),
                "A raw Color(red:) literal was reintroduced inside the pump-chip vocabulary — must reference AppTheme instead")
    }

    // MARK: - Vacuous-pass guard

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors
    /// `BandDriftGuardTests.fileResolutionActuallyFoundTheRepoRoot`).
    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(Self.repoRootURL() != nil,
                "drift-guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
