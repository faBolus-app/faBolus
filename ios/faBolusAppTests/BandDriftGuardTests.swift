import Testing
import Foundation
@testable import faBolus

/// **SC2/SC3 drift-guard (Phase 09.1, D-06; T-09.1-10/T-09.1-11).** Proves the Plan 01-04 extraction is
/// SELF-ENFORCING: no production surface outside `faBolusDesign`/`faBolusCore` may hardcode a raw
/// band-color literal inside a function/property that classifies a glucose band. Modeled on this repo's
/// two existing Phase-7 boundary suites — `NudgeDeliveryBoundaryTests.balancedFunctionBody` (the
/// brace-balance slicer) and `LiveActivityBoundaryTests.allSwiftFiles(under:)` (the repo-wide `.swift`
/// enumerator) — reused here rather than reinvented (09.1-RESEARCH.md "Code Examples").
///
/// Two independent prongs (09.1-RESEARCH.md Pitfall 4 — a whole-file/whole-function raw-color ban
/// false-positives on ~20+ legitimate, unrelated raw-color sites already in this repo: staleness
/// captions, pairing/auth status, bolus-outcome tint, generic error text):
///
/// 1. **Forward scan** — locate every band-classification entry point (`GlucoseRange.classify(`,
///    `.rangeCategory`, `WidgetSnapshot.rangeCategory(`) in production source, slice the SMALLEST
///    brace-balanced block already open around that line, and assert the slice is free of raw
///    band-color identifiers. Scoping to the SMALLEST enclosing block — not the whole outer function,
///    as the RESEARCH's own sketch implies — matters here: `StatusRingView.content(now:)` and
///    `WatchGlanceView.body` both contain a classify call inside one small
///    `if present == .fresh { ... }` block AND an unrelated, legitimate raw `.orange` SIBLING statement
///    later in the SAME outer function (a failover badge / a stale-age caption — neither classifies a
///    band). A function-level slice would false-positive on those two real sites; a block-level slice,
///    scoped to whatever brace is innermost-open at the moment the classify line is reached, does not —
///    the sibling statement's own braces open only AFTER the classifying block has already closed, so
///    they are never part of the same slice.
/// 2. **Deletion-assertion** — the concrete duplicate-classifier sites this phase deleted (Plans
///    01-05; 09.1-RESEARCH.md "Summary count") are confirmed gone from production source.
struct BandDriftGuardTests {

    // MARK: - Scan vocabulary

    /// The only symbols this scan treats as "this block classifies a glucose band". Held as a
    /// `String` array (not `Set`) because scan order doesn't matter and duplicates are harmless.
    static let bandClassificationEntryPoints = [
        "GlucoseRange.classify(", ".rangeCategory", "WidgetSnapshot.rangeCategory(",
    ]

    /// Forbidden raw `Color` identifiers inside a classifying block, outside `faBolusDesign`/
    /// `faBolusCore` (the two modules that own the ONE sanctioned mapping,
    /// `faBolusDesign.AppTheme.glucoseColor`). These are the exact four bare system colors every
    /// surface's now-deleted local switch used (09.1-RESEARCH.md "Deprecated/outdated"), plus a raw
    /// literal-RGB constructor.
    static let forbiddenRawBandColors = [".red", ".green", ".yellow", ".orange", "Color(red:"]

    // MARK: - Repo enumeration (mirrors LiveActivityBoundaryTests' idiom)

    /// Resolve the repo root by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/BandDriftGuardTests.swift`) until `project.yml` — a stable,
    /// always-checked-in repo-root marker — is found. Same walk-up technique as
    /// `LiveActivityBoundaryTests.intentsFileURL()`/`RescueCarbGuardTests.scanRoots()`.
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

    /// Recursively enumerate every production `.swift` file under `root`, skipping build artifacts,
    /// any `*Tests` directory (this file's own directory included — its `forbiddenRawBandColors`/
    /// `bandClassificationEntryPoints` string constants are the scan's NEEDLES, not something to scan),
    /// and `faBolusDesign`/`faBolusCore` — the two modules that own the one sanctioned classifier +
    /// color mapping and are explicitly out of this scan's scope (D-06's own wording: "outside
    /// faBolusDesign/faBolusCore"). `.skipsHiddenFiles` already drops dotfile dirs (`.git`, `.build`,
    /// `.claude`, `.gsd`, any stale sibling git worktree checked out under a hidden dir) — the explicit
    /// list below is belt-and-suspenders for non-hidden build/dependency directories, mirroring
    /// `LiveActivityBoundaryTests.allSwiftFiles(under:)` verbatim plus the two package exemptions.
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let skipDirNames: Set<String> = [
            ".build", "DerivedData", "Pods", ".git", "node_modules",
            "faBolusDesign", "faBolusCore",
        ]
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

    /// Strip `//`-style line comments — necessary because several production files' OWN doc comments
    /// legitimately name the deleted symbols/forbidden identifiers in prose (explaining what must never
    /// reappear in CODE; see e.g. `mac/faBolusMac/MacComponents.swift`'s doc comment naming
    /// `RemoteClientModel.band`), so an unstripped scan would false-positive on those doc comments.
    /// Same technique as `LiveActivityBoundaryTests.stripLineComments`.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let idx = line.range(of: "//") { return String(line[..<idx.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    // MARK: - Block-level brace slicer

    /// Returns the line index of the SMALLEST `{` already open at the moment `targetIdx` is reached —
    /// i.e. the start of the nearest enclosing brace-balanced block containing that line, not
    /// necessarily the whole enclosing function/property. `nil` if `targetIdx` is at top level (should
    /// never happen for a real classify call, which always lives inside some declaration's body).
    private static func smallestEnclosingBlockStart(forLineIndex targetIdx: Int, in lines: [String]) -> Int? {
        var stack: [Int] = []
        for (idx, line) in lines.enumerated() {
            if idx == targetIdx { return stack.last }
            for ch in line {
                if ch == "{" { stack.append(idx) }
                else if ch == "}" { if !stack.isEmpty { stack.removeLast() } }
            }
        }
        return nil
    }

    /// Balanced-brace forward slice starting at `startIdx` through its matching close — the same
    /// technique as `NudgeDeliveryBoundaryTests.balancedFunctionBody(signaturePrefix:in:)`, generalized
    /// to start at an explicit line index instead of a signature-prefix search (this scan doesn't know
    /// function signatures ahead of time; `smallestEnclosingBlockStart` already found the right line).
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

    // MARK: - Prong 1: forward scan (SC2)

    /// Every function/computed-property that classifies a glucose band, anywhere in production source
    /// outside `faBolusDesign`/`faBolusCore`, must not ALSO hardcode a raw band-color literal in the
    /// same immediate block. Also a loud-not-vacuous guard (mirrors
    /// `RescueCarbGuardTests`/`LiveActivityBoundaryTests`' own `scanned > 0` pattern): a path/regex
    /// regression must fail loudly, not pass by scanning nothing.
    @Test func noRawBandColorInsideAnyClassifyingBlockOutsideDesignOrCore() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        var scannedBlocks = 0
        var violations: [String] = []

        for url in Self.allSwiftFiles(under: repoRoot) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = Self.stripLineComments(raw)
            let lines = stripped.components(separatedBy: "\n")
            var checkedStarts = Set<Int>()

            for (idx, line) in lines.enumerated() {
                guard Self.bandClassificationEntryPoints.contains(where: { line.contains($0) }) else { continue }
                let startIdx = Self.smallestEnclosingBlockStart(forLineIndex: idx, in: lines) ?? idx
                guard !checkedStarts.contains(startIdx) else { continue }
                checkedStarts.insert(startIdx)
                scannedBlocks += 1

                let slice = Self.balancedSlice(startingAt: startIdx, in: lines)
                for forbidden in Self.forbiddenRawBandColors where slice.contains(forbidden) {
                    violations.append("\(url.lastPathComponent):\(startIdx + 1) contains forbidden raw band-color literal '\(forbidden)'")
                }
            }
        }

        #expect(violations.isEmpty,
                "Band-color drift-guard violated:\n\(violations.joined(separator: "\n"))")
        #expect(scannedBlocks > 0,
                "expected to find at least one band-classifying block under \(repoRoot.path) — scan broke (would otherwise pass vacuously)")
    }

    /// Pins the scan's scope boundary (09.1-RESEARCH.md Open Questions #1/#2, Assumptions A2/A3):
    /// the AGP 5-way Time-in-Range bar (`StatsCardView.tirBar`, classifies via `GlucoseStatistics`
    /// percentages, not `GlucoseRange`) and the glucose chart scatter-points (`GlucoseChartView.body`,
    /// `WatchChartView.body`, `MacComponents.MacChartView`, all coloring per-point via
    /// `AppTheme.glucoseColor` directly with no local classify call) are deliberately OUT of D-01..D-07's
    /// scope and must NOT be flagged. This documents + freezes today's boundary — if a future refactor
    /// wires either surface through a sanctioned entry point directly, the forward scan above starts
    /// covering it automatically; until then, this test proves they aren't silently exempted by a
    /// scan bug rather than by design (each of these declarations genuinely contains zero sanctioned
    /// entry points today).
    @Test func agpBarAndChartScatterPointsContainNoDirectClassifyEntryPoint() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        let pins: [(file: String, signature: String)] = [
            ("ios/faBolus/Views/StatsCardView.swift", "func tirBar("),
            ("ios/faBolus/Views/GlucoseChartView.swift", "var body: some View {"),
            ("watch/faBolusWatch/WatchChartView.swift", "var body: some View {"),
            ("mac/faBolusMac/MacComponents.swift", "struct MacChartView: View {"),
        ]
        for pin in pins {
            let url = repoRoot.appendingPathComponent(pin.file)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            let lines = stripped.components(separatedBy: "\n")
            let slice = try Self.functionSlice(signaturePrefix: pin.signature, in: lines, file: pin.file)
            let hit = Self.bandClassificationEntryPoints.first { slice.contains($0) }
            #expect(hit == nil,
                    "\(pin.file)'s \(pin.signature) unexpectedly contains a band-classification entry point ('\(hit ?? "")') — it is scoped OUT of D-01..D-07 (RESEARCH Open Qs #1/#2); if this is now intentional, this pin needs an owner-reviewed update, not a silent pass")
        }
    }

    /// Locate a declaration by its signature-line substring and slice it via balanced braces — same
    /// idea as `NudgeDeliveryBoundaryTests.balancedFunctionBody(signaturePrefix:in:)`, adapted to take
    /// pre-split lines (this file already splits once per source file for the main scan).
    private static func functionSlice(signaturePrefix: String, in lines: [String], file: String) throws -> String {
        guard let startIdx = lines.firstIndex(where: { $0.contains(signaturePrefix) }) else {
            throw SliceError.signatureNotFound("\(signaturePrefix) in \(file)")
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

    // MARK: - Prong 2: deletion assertion (SC1/D-03)

    /// The concrete duplicate-classifier sites this phase deleted (Plans 01-05) are confirmed gone from
    /// production source. `MacTheme.swift` is checked by file-existence (the whole file was deleted,
    /// 09.1-04); the rest are checked by their EXACT original signature text (captured from git history
    /// at the commit immediately before each deletion), so a future re-addition under the same name is
    /// caught even if the body changes.
    @Test func legacyBandColorDuplicateSitesAreAllDeleted() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")

        let macThemeURL = repoRoot.appendingPathComponent("mac/faBolusMac/MacTheme.swift")
        #expect(!FileManager.default.fileExists(atPath: macThemeURL.path),
                "mac/faBolusMac/MacTheme.swift should remain deleted (09.1-04)")

        // Exact original signatures, verified against git history immediately before each deletion:
        // watchGlucoseColor (commit a341263^), WidgetUI/MacWidgetUI's shared glucoseColor(_ category:)
        // shape (commits 4b56382^/8d824cc^), the complication's private color switch (a341263^), and
        // this plan's own Task 1 deletion (band(_:), verified earlier in this plan against HEAD~1).
        let forbiddenDeclarations = [
            "func watchGlucoseColor(",
            "glucoseColor(_ category: Int)",
            "MacWidgetUI",
            "func color(_ snap: WidgetSnapshot, now: Date) -> Color",
            "static func band(_ mgdl: Int) -> Int",
        ]

        var hits: [String] = []
        for url in Self.allSwiftFiles(under: repoRoot) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = Self.stripLineComments(raw)
            for symbol in forbiddenDeclarations where stripped.contains(symbol) {
                hits.append("\(url.lastPathComponent) contains resurfaced symbol '\(symbol)'")
            }
        }
        #expect(hits.isEmpty,
                "Deleted band-color duplicate symbol(s) resurfaced:\n\(hits.joined(separator: "\n"))")
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors
    /// `LiveActivityBoundaryTests.fileResolutionActuallyFoundTheIntentsFile`).
    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(Self.repoRootURL() != nil,
                "drift-guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
