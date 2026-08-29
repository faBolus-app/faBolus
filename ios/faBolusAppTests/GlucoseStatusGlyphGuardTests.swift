import Testing
import Foundation
@testable import faBolus

/// Pins that glucose surfaces never reintroduce a good/bad band glyph; trend arrows and VoiceOver
/// zone words stay, because display-only must never look like a dose-quality signal.
struct GlucoseStatusGlyphGuardTests {

    // MARK: - Scan vocabulary

    /// Forbidden band-glyph forms. Not a bare `symbolName` string — that collides with unrelated types.
    static let bandGlyphNeedles = [
        "BandIndicator(", "band.symbolName", "band?.symbolName"
    ]

    /// Literal SF Symbols the deleted band glyph used — forbidden only on a line that also has a ternary.
    static let bandGlyphSymbolNeedles = [
        "arrow.down.circle.fill", "checkmark.circle.fill", "arrow.up.circle.fill", "exclamationmark.triangle.fill"
    ]

    /// Real CGM trend-arrow tokens that must survive; display-only, never a dose-quality signal.
    static let trendArrowNeedles = [".trend", "snap.trendArrow", "context.arrow"]

    /// VoiceOver zone word that some accessibility annotation must still carry.
    static let zoneWordNeedle = ".shortLabel"

    /// Glucose surfaces the glyph must not reappear on.
    static let pinnedSurfaces = [
        "ios/faBolus/Views/StatusRingView.swift",
        "ios/faBolusWidgets/GlucoseWidget.swift",
        "ios/faBolusWidgets/StatusWidget.swift"
    ]

    // MARK: - Repo enumeration (mirrors BandDriftGuardTests' idiom)

    /// Resolve the repo root by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/GlucoseStatusGlyphGuardTests.swift`) until `project.yml` — a
    /// stable, always-checked-in repo-root marker — is found. Same walk-up technique as
    /// `BandDriftGuardTests.repoRootURL()`.
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

    /// Strip `//`-style line comments — necessary because this file's own doc comments legitimately
    /// name the forbidden needles in prose (explaining what must never reappear in CODE), so an
    /// unstripped scan would false-positive on doc comments. Same technique as
    /// `BandDriftGuardTests.stripLineComments`.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let idx = line.range(of: "//") { return String(line[..<idx.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Balanced-brace forward slice starting at `startIdx` through its matching close — same
    /// technique as `BandDriftGuardTests.balancedSlice`. IN-02 (09.29 review): exercised directly by
    /// `balancedSliceExtractsExactlyOneBalancedBraceBlock` below (previously dead code with no caller
    /// and no test coverage); this guard's own scans use the simpler line-prefix `splitIntoRenderBlocks`
    /// below instead, since the pinned surfaces' switch-based family/region boundaries are more
    /// reliably located by line prefix (`case `/`default:`/`struct `/`func `) than by raw brace-depth,
    /// which can't tell a `switch`'s own opening brace apart from a nested `if`/closure's.
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

    /// Splits a pinned surface into independent render blocks (case/default/struct/func) so a
    /// per-block trend-arrow count can catch a stray duplicate without false-positiving on
    /// WidgetFamily cases that each render the trend once.
    private static func splitIntoRenderBlocks(_ source: String) -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [[String]] = [[]]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBoundary =
                trimmed.hasPrefix("case ") || trimmed.hasPrefix("default:")
                || trimmed.range(
                    of: #"^(private |internal |public |fileprivate |static )*(struct|func) \w"#,
                    options: .regularExpression) != nil
            if isBoundary { blocks.append([]) }
            blocks[blocks.count - 1].append(line)
        }
        return blocks.map { $0.joined(separator: "\n") }
    }

    /// WR-01: counts trend-arrow RENDER lines in a block — a line must contain a rendering call
    /// (`Text(`/`Label(`) AND one of `trendArrowNeedles`, not just the bare token (which would also
    /// match the token's own non-rendering definition/composition, e.g. `private var arrow: String { … }`
    /// or an accessibility-label string builder).
    private static func countTrendRenders(in block: String) -> Int {
        block.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { count, line in
            let hasCall = line.contains("Text(") || line.contains("Label(")
            let hasToken = Self.trendArrowNeedles.contains { line.contains($0) }
            return count + ((hasCall && hasToken) ? 1 : 0)
        }
    }

    // MARK: - Tests

    /// Every pinned glucose surface must contain no band glyph, and must not hardcode a
    /// ternary-selected band SF Symbol. Ternary scoping avoids false positives on unrelated uses
    /// of the same common symbols. Scanned count must equal the pinned list, not a broken scan.
    @Test func noPinnedSurfaceContainsABandGlyph() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        var scanned = 0
        var violations: [String] = []

        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            scanned += 1
            for needle in Self.bandGlyphNeedles where stripped.contains(needle) {
                violations.append("\(path) contains forbidden band-glyph needle '\(needle)'")
            }
            for line in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.contains("?") else { continue }
                for needle in Self.bandGlyphSymbolNeedles where line.contains(needle) {
                    violations.append(
                        "\(path) hardcodes a ternary-selected band SF Symbol '\(needle)': \(line.trimmingCharacters(in: .whitespaces))"
                    )
                }
            }
        }

        #expect(
            violations.isEmpty,
            "Band-glyph regression guard violated:\n\(violations.joined(separator: "\n"))")
        #expect(
            scanned == 3,
            "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)"
        )
    }

    /// Prong 2 (trend-arrow survives — presence): every pinned surface still renders its trend token
    /// (one of `.trend` / `snap.trendArrow` / `context.arrow`) AT LEAST ONCE somewhere in the file,
    /// proving the real CGM trend arrow was never deleted alongside the band glyph. This is a presence
    /// check ONLY — see `everyRenderBlockRendersItsTrendArrowAtMostOnce` below for the uniqueness prong
    /// (WR-01: the two together give "exactly once per render occasion," which a single whole-file
    /// `contains` can't express since several pinned surfaces legitimately render the trend arrow once
    /// EACH across multiple independent regions/families). Loud-not-vacuous: scanned count == 3.
    @Test func everyPinnedSurfaceStillRendersItsTrendToken() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        var scanned = 0
        var missing: [String] = []

        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            scanned += 1
            let hasTrendToken = Self.trendArrowNeedles.contains { stripped.contains($0) }
            if !hasTrendToken {
                missing.append("\(path) is missing every trend-arrow token \(Self.trendArrowNeedles)")
            }
        }

        #expect(
            missing.isEmpty,
            "Trend-arrow regression:\n\(missing.joined(separator: "\n"))")
        #expect(
            scanned == 3,
            "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)"
        )
    }

    /// Prong 2b (trend-arrow survives — uniqueness, WR-01): every independent render block
    /// (`splitIntoRenderBlocks`) in every pinned surface renders its trend-arrow token AT MOST ONCE —
    /// catching a future regression where a surface accidentally renders the token TWICE within the
    /// SAME block (e.g. a stray duplicate `Text(context.arrow)`), which the presence-only prong above
    /// cannot detect (`contains` is satisfied by one occurrence or many). Scoped per render block, not
    /// per whole file, because several pinned surfaces legitimately render the trend arrow once EACH
    /// across multiple mutually-exclusive `WidgetFamily` `case`s or multiple independent region-backing
    /// `struct`s/`func`s (confirmed by inspection — a flat whole-file "exactly one" would false-positive
    /// on today's correct `GlucoseWidget.swift` (and, before its Phase 7 removal, `GlucoseLiveActivity
    /// .swift`). Loud-not-vacuous:
    /// scanned == 3.
    @Test func everyRenderBlockRendersItsTrendArrowAtMostOnce() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        var scanned = 0
        var violations: [String] = []

        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            scanned += 1
            for block in Self.splitIntoRenderBlocks(stripped) {
                let count = Self.countTrendRenders(in: block)
                if count > 1 {
                    let firstLine = block.split(separator: "\n").first.map(String.init) ?? "<empty>"
                    violations.append(
                        "\(path): render block starting '\(firstLine.trimmingCharacters(in: .whitespaces))' renders the trend arrow \(count) times (expected at most 1)"
                    )
                }
            }
        }

        #expect(
            violations.isEmpty,
            "Duplicate trend-arrow render:\n\(violations.joined(separator: "\n"))")
        #expect(
            scanned == 3,
            "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)"
        )
    }

    /// CR-01 GUARD (09.29 review): every pinned surface's (comment-stripped) source contains BOTH the
    /// VoiceOver zone-word token (`zoneWordNeedle`, `.shortLabel`) AND an `accessibilityLabel(`/
    /// `accessibilityValue(` call — a text-scan proxy proving the zone word feeds SOME spoken
    /// accessibility annotation in the file, so a future deletion (like the one this review found,
    /// where 5 of 8 surfaces lost their ONLY VoiceOver band cue when `BandIndicator` was removed) can't
    /// silently drop it again without failing this test. NOT full UI-tree/snapshot verification — the
    /// review's own words: "the existing text-scan guard can't verify accessibility wiring." Loud-not-
    /// vacuous: scanned == 3.
    @Test func everyPinnedSurfaceSpeaksTheZoneWordToVoiceOver() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        var scanned = 0
        var missing: [String] = []

        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            scanned += 1
            let hasZoneWord = stripped.contains(Self.zoneWordNeedle)
            let hasAccessibilityAnnotation =
                stripped.contains("accessibilityLabel(") || stripped.contains("accessibilityValue(")
            if !(hasZoneWord && hasAccessibilityAnnotation) {
                missing.append(
                    "\(path) is missing the VoiceOver zone-word cue (needs both '\(Self.zoneWordNeedle)' and an accessibilityLabel(/accessibilityValue( call)"
                )
            }
        }

        #expect(
            missing.isEmpty,
            "VoiceOver zone-word regression:\n\(missing.joined(separator: "\n"))")
        #expect(
            scanned == 3,
            "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)"
        )
    }

    /// Loud-not-vacuous plumbing check (mirrors `BandDriftGuardTests.fileResolutionActuallyFoundTheRepoRoot`):
    /// a path-resolution bug must fail loudly, not pass vacuously. Also pins the exact surface count.
    @Test func guardResolvesRepoRootAndScansAllThreeGlucoseSurfaces() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
        #expect(
            Self.pinnedSurfaces.count == 3,
            "expected exactly 3 pinned glucose surfaces (09.29-DIAGNOSIS.md §A, minus the Mac + Watch + Live Activity surfaces removed by 03-01/03-03/07-01 delete-on-main) — pin list drifted"
        )
        var scannedSurfaces = 0
        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "pinned glucose surface does not exist at \(url.path)")
            guard (try? String(contentsOf: url, encoding: .utf8)) != nil else {
                Issue.record("pinned glucose surface could not be read at \(url.path)")
                continue
            }
            scannedSurfaces += 1
        }
        #expect(
            scannedSurfaces == 3,
            "expected to actually read all 3 pinned glucose surfaces — plumbing broke (would otherwise pass vacuously)")
    }

    /// IN-02 (09.29 review): direct unit coverage for `balancedSlice` — previously dead code with no
    /// caller and no test, kept only to mirror `BandDriftGuardTests`' shape for possible future reuse.
    /// Proves it extracts exactly the balanced-brace block starting at the given line, stopping at the
    /// FIRST matching close brace, and does not spill into a sibling block that follows.
    @Test func balancedSliceExtractsExactlyOneBalancedBraceBlock() {
        let lines = [
            "struct Foo {",
            "    if x {",
            "        doSomething()",
            "    }",
            "}",
            "struct Bar {",
            "    doOther()",
            "}"
        ]
        let slice = Self.balancedSlice(startingAt: 0, in: lines)
        #expect(slice.contains("doSomething()"), "expected the slice to include its own nested content")
        #expect(
            !slice.contains("doOther()"),
            "expected the slice to stop at its own matching close brace, not spill into the next block")
        #expect(slice.hasPrefix("struct Foo {"), "expected the slice to start at the requested line")
    }
}
