import Testing
import Foundation
@testable import faBolus

/// Production surfaces must not hardcode band colors next to classify; glucose color is
/// display-only and must stay in the one sanctioned mapping.
struct BandDriftGuardTests {

    // MARK: - Scan vocabulary

    /// The only symbols this scan treats as "this block classifies a glucose band". Held as a
    /// `String` array (not `Set`) because scan order doesn't matter and duplicates are harmless.
    static let bandClassificationEntryPoints = [
        "GlucoseRange.classify(", ".rangeCategory", "WidgetSnapshot.rangeCategory("
    ]

    /// Forbidden raw Color identifiers inside a classifying block. Glucose color is display-only
    /// and must stay in `AppTheme.glucoseColor`.
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

    /// Production `.swift` files, skipping tests and the two modules that own the sanctioned
    /// classifier (`faBolusDesign`/`faBolusCore`).
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let skipDirNames: Set<String> = [
            ".build", "DerivedData", "Pods", ".git", "node_modules",
            "faBolusDesign", "faBolusCore"
        ]
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
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

    /// Strip line comments so a scan does not false-positive on docs that name forbidden tokens.
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
                if ch == "{" { stack.append(idx) } else if ch == "}" { if !stack.isEmpty { stack.removeLast() } }
            }
        }
        return nil
    }

    /// Balanced-brace forward slice starting at `startIdx` through its matching close — the same
    /// balanced-brace-scan technique as `functionSlice(signaturePrefix:in:file:)` below, generalized
    /// to start at an explicit line index instead of a signature-prefix search (this scan doesn't know
    /// function signatures ahead of time; `smallestEnclosingBlockStart` already found the right line).
    private static func balancedSlice(startingAt startIdx: Int, in lines: [String]) -> String {
        var depth = 0
        var opened = false
        var collected: [String] = []
        for line in lines[startIdx...] {
            collected.append(line)
            for ch in line {
                if ch == "{" {
                    depth += 1
                    opened = true
                } else if ch == "}" {
                    depth -= 1
                }
            }
            if opened && depth <= 0 { break }
        }
        return collected.joined(separator: "\n")
    }

    // MARK: - Forward scan

    /// A classifying block must not hardcode a raw band color. Fail loudly if the scan finds nothing.
    @Test func noRawBandColorInsideAnyClassifyingBlockOutsideDesignOrCore() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
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
                    violations.append(
                        "\(url.lastPathComponent):\(startIdx + 1) contains forbidden raw band-color literal '\(forbidden)'"
                    )
                }
            }
        }

        #expect(
            violations.isEmpty,
            "Band-color drift-guard violated:\n\(violations.joined(separator: "\n"))")
        #expect(
            scannedBlocks > 0,
            "expected to find at least one band-classifying block under \(repoRoot.path) — scan broke (would otherwise pass vacuously)"
        )
    }

    /// `tirBar` and the chart scatter points color via `AppTheme` with no local classify call, so
    /// they stay out of the classify-entry-point scan by design, not a scan bug.
    @Test func agpBarAndChartScatterPointsContainNoDirectClassifyEntryPoint() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        let pins: [(file: String, signature: String)] = [
            ("ios/faBolus/Views/StatsCardView.swift", "func tirBar("),
            ("ios/faBolus/Views/GlucoseChartView.swift", "var body: some View {")
        ]
        for pin in pins {
            let url = repoRoot.appendingPathComponent(pin.file)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            let lines = stripped.components(separatedBy: "\n")
            let slice = try Self.functionSlice(signaturePrefix: pin.signature, in: lines, file: pin.file)
            let hit = Self.bandClassificationEntryPoints.first { slice.contains($0) }
            #expect(
                hit == nil,
                "\(pin.file)'s \(pin.signature) unexpectedly contains a band-classification entry point ('\(hit ?? "")') — it is scoped OUT of the band-classification scope; if this is now intentional, this pin needs an owner-reviewed update, not a silent pass"
            )
        }
    }

    /// `tirBar` classifies via percentages, not `GlucoseRange.classify`, so it is also scanned
    /// directly: raw band-color literals must not resurface there.
    @Test func noRawBandColorInStatsCardViewTirBar() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        let file = "ios/faBolus/Views/StatsCardView.swift"
        let url = repoRoot.appendingPathComponent(file)
        let raw = try String(contentsOf: url, encoding: .utf8)
        let stripped = Self.stripLineComments(raw)
        let lines = stripped.components(separatedBy: "\n")
        let slice = try Self.functionSlice(signaturePrefix: "func tirBar(", in: lines, file: file)

        let violations = Self.forbiddenRawBandColors.filter { slice.contains($0) }
        #expect(
            violations.isEmpty,
            "tirBar still contains forbidden raw band-color literal(s): \(violations.joined(separator: ", "))")
        #expect(
            !slice.isEmpty,
            "expected to scan tirBar's body — resolution broke (would otherwise pass vacuously)")
    }

    /// Locate a declaration by its signature-line substring and slice it via balanced braces — same
    /// balanced-brace-scan idea as `balancedSlice(startingAt:in:)` above, but searches by signature
    /// prefix instead of a known line index (pre-split lines; this file already splits once per source
    /// file for the main scan).
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

    // MARK: - Deleted duplicate classifiers must not return

    /// Duplicate band-color classifiers deleted from production must stay gone.
    @Test func legacyBandColorDuplicateSitesAreAllDeleted() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")

        let macThemeURL = repoRoot.appendingPathComponent("mac/faBolusMac/MacTheme.swift")
        #expect(
            !FileManager.default.fileExists(atPath: macThemeURL.path),
            "mac/faBolusMac/MacTheme.swift should remain deleted")

        // Exact original signatures, verified against git history immediately before each deletion:
        // watchGlucoseColor (commit a341263^), WidgetUI/MacWidgetUI's shared glucoseColor(_ category:)
        // shape (commits 4b56382^/8d824cc^), the complication's private color switch (a341263^), and
        // and the band(_:) deletion itself (verified against HEAD~1).
        let forbiddenDeclarations = [
            "func watchGlucoseColor(",
            "glucoseColor(_ category: Int)",
            "MacWidgetUI",
            "func color(_ snap: WidgetSnapshot, now: Date) -> Color",
            "static func band(_ mgdl: Int) -> Int"
        ]

        var hits: [String] = []
        for url in Self.allSwiftFiles(under: repoRoot) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = Self.stripLineComments(raw)
            for symbol in forbiddenDeclarations where stripped.contains(symbol) {
                hits.append("\(url.lastPathComponent) contains resurfaced symbol '\(symbol)'")
            }
        }
        #expect(
            hits.isEmpty,
            "Deleted band-color duplicate symbol(s) resurfaced:\n\(hits.joined(separator: "\n"))")
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors
    /// `LiveActivityBoundaryTests.fileResolutionActuallyFoundTheIntentsFile`).
    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(
            Self.repoRootURL() != nil,
            "drift-guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
