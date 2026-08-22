import Testing
import Foundation
@testable import faBolus

/// **D-05 full-surface regression guard (Phase 09.29, Plan 05 teardown).** Proves the deletion of the
/// confusing good/bad `BandIndicator` glyph — swept across ALL eight glucose surfaces by waves 01-04 —
/// is SELF-ENFORCING going forward, and that each surface's real CGM trend arrow survives the edit.
/// Started as a one-surface tracer scaffold in 09.29-01 (scoped to `StatusRingView.swift` only);
/// expansion waves 02-04 swept the remaining call sites; this teardown wave widens the scan to the full
/// eight-surface list per 09.29-DIAGNOSIS.md §A, now that `GlucoseRange.symbolName` and
/// `BandIndicator.swift` are deleted (09.29-05 Task 1). Modeled on `BandDriftGuardTests`' repo-walk-up +
/// loud-not-vacuous idiom (09.29-CONTEXT.md D-05).
///
/// The scan needles are DELIBERATELY narrow: the shared glyph view's instantiation (`BandIndicator(`)
/// and the glucose band-symbol expression forms (`band.symbolName` / `band?.symbolName`) — NEVER a bare
/// `symbolName` grep. `ClinicianTierAck`/`StoredSettingChange` own an unrelated `symbolName` used in
/// `SettingChangeLogView.swift` and `PumpWizardViews.swift` (name collision; neither file is in the
/// pinned surface list below) — a bare-string needle would false-positive on those.
///
/// WR-02 (09.29 review) — the needle list ALSO forbids a hardcoded, ternary-selected reintroduction of
/// one of the four literal SF Symbol strings the deleted `GlucoseRange.symbolName` used to produce
/// (`bandGlyphSymbolNeedles` below), catching a differently-named reintroduction of the same confusing
/// good/bad-glyph pattern, not just a literal `BandIndicator` type. That check is scoped to lines that
/// ALSO contain a ternary (`?` … `:`) — a band-conditioned glyph CHOICE — so it does not false-positive
/// on legitimate, unconditional, unrelated uses of the same common SF Symbols. (Historical note: two of
/// the original eight pinned files — `mac/faBolusMac/MacComponents.swift`'s `MacAlertsView` pump-alert
/// triangle and `mac/faBolusMacWidgets/FaBolusMacWidgetBundle.swift`'s `MacQuickBolusWidget`
/// delivered/failed status icons — were the motivating false-positive case for this ternary scoping;
/// both were git rm'd from `main` in Phase 3's Mac-remote delete-on-main plan (03-01) and removed from
/// `pinnedSurfaces` below — out-of-scope fix, see 03-02-SUMMARY.md.)
///
/// CR-01 (09.29 review): `everyPinnedSurfaceSpeaksTheZoneWordToVoiceOver` below additionally guards
/// the VoiceOver zone-word regression this review found — 5 of the 8 pinned surfaces had NO
/// accessibility mechanism for the band other than the now-deleted `BandIndicator`'s own
/// `.accessibilityLabel(shortLabel)`, and lost the spoken cue entirely when it was deleted with no test
/// catching the gap. This is a text-scan proxy (proves `.shortLabel` feeds SOME
/// `.accessibilityLabel`/`.accessibilityValue` in the file), not full UI-tree/snapshot verification —
/// the review's own words: "the existing text-scan guard can't verify accessibility wiring."
struct GlucoseStatusGlyphGuardTests {

    // MARK: - Scan vocabulary

    /// The band-glyph forms this guard forbids inside a glucose surface. Deliberately NOT a bare
    /// `symbolName` string — see file doc comment.
    static let bandGlyphNeedles = [
        "BandIndicator(", "band.symbolName", "band?.symbolName",
    ]

    /// WR-02: the four literal SF Symbol strings `GlucoseRange.symbolName` used to produce before its
    /// deletion — forbidden ONLY on a line that also contains a ternary (`?`), see file doc comment.
    static let bandGlyphSymbolNeedles = [
        "arrow.down.circle.fill", "checkmark.circle.fill", "arrow.up.circle.fill", "exclamationmark.triangle.fill",
    ]

    /// The real CGM trend-arrow tokens that must survive the band-glyph removal — every pinned surface
    /// renders its trend through one of these three forms (09.29-05-PLAN.md Task 2).
    static let trendArrowNeedles = [".trend", "snap.trendArrow", "context.arrow"]

    /// CR-01 GUARD: the VoiceOver zone word this guard now requires SOME accessibility annotation to carry.
    static let zoneWordNeedle = ".shortLabel"

    /// The glucose surfaces the D-02 sweep (waves 01-04) touched, pinned BY PATH
    /// (09.29-DIAGNOSIS.md §A table) — originally eight; six after Phase 3 (03-01) git rm'd
    /// `mac/faBolusMac/MacComponents.swift` + `mac/faBolusMacWidgets/FaBolusMacWidgetBundle.swift` from
    /// `main` (preserved on dev/mac) — out-of-scope fix, see 03-02-SUMMARY.md; four after Phase 3
    /// (03-03) git rm'd `watch/faBolusWatch/WatchHUDView.swift` +
    /// `watch/faBolusWatchWidgets/GlucoseComplication.swift` from `main` (preserved on dev/watch-remote,
    /// REMOTE-03, delete-on-main) — same out-of-scope-fix posture as the Mac removal above; now three
    /// after Phase 7 (07-01, FEAT-01) git rm'd `ios/faBolusWidgets/GlucoseLiveActivity.swift` from
    /// `main` (preserved on dev/live-activity) — same out-of-scope-fix posture again.
    static let pinnedSurfaces = [
        "ios/faBolus/Views/StatusRingView.swift",
        "ios/faBolusWidgets/GlucoseWidget.swift",
        "ios/faBolusWidgets/StatusWidget.swift",
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
                if ch == "{" { depth += 1; opened = true }
                else if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        return collected.joined(separator: "\n")
    }

    /// WR-01 (09.29 review): splits a pinned surface's (comment-stripped) source into independent
    /// "render blocks" — everything between one boundary line and the next — so a per-block trend-arrow
    /// count can catch a future STRAY DUPLICATE render within the SAME block, without false-positiving
    /// on the many pinned surfaces that legitimately render the trend arrow once EACH in several
    /// separate blocks (e.g. `GlucoseWidget.swift`'s four `WidgetFamily` `case`s, or the now-removed
    /// `GlucoseLiveActivity.swift`'s several independent region-backing `struct`s/`func`s it was
    /// originally written against). A boundary is
    /// any line (after trimming) that starts a new `case`/`default:` switch arm, or a new
    /// `struct`/`func` declaration — the granularity at which "one render" is actually meaningful for
    /// these files (confirmed by inspection: every pinned surface's trend-arrow renders each land in
    /// their own such block today).
    private static func splitIntoRenderBlocks(_ source: String) -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [[String]] = [[]]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBoundary = trimmed.hasPrefix("case ") || trimmed.hasPrefix("default:")
                || trimmed.range(of: #"^(private |internal |public |fileprivate |static )*(struct|func) \w"#,
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

    /// Prong 1 (glyph-gone): every pinned glucose surface, stripped of comments, must contain none of
    /// `bandGlyphNeedles`, AND (WR-02) must not hardcode a ternary-selected literal SF Symbol string
    /// from `bandGlyphSymbolNeedles` (the exact strings the deleted `GlucoseRange.symbolName` produced)
    /// — catching a differently-named reintroduction of the same confusing good/bad-glyph pattern, e.g.
    /// `Image(systemName: g < 70 ? "arrow.down.circle.fill" : "checkmark.circle.fill")`. The symbol
    /// check requires a ternary (`?`) on the SAME line as the needle, so it does not false-positive on
    /// this file set's two legitimate, unconditional, unrelated uses of these same common SF Symbols
    /// (`MacComponents.swift`'s `MacAlertsView` pump-alert triangle, `FaBolusMacWidgetBundle.swift`'s
    /// `MacQuickBolusWidget` delivered/failed status icons — see file doc comment). Loud-not-vacuous:
    /// asserts the scanned count equals eight — the full pinned list, not a partial/broken scan.
    @Test func noPinnedSurfaceContainsABandGlyph() throws {
        let repoRoot = try #require(Self.repoRootURL(),
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
                    violations.append("\(path) hardcodes a ternary-selected band SF Symbol '\(needle)': \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(violations.isEmpty,
                "Band-glyph regression guard violated:\n\(violations.joined(separator: "\n"))")
        #expect(scanned == 3,
                "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)")
    }

    /// Prong 2 (trend-arrow survives — presence): every pinned surface still renders its trend token
    /// (one of `.trend` / `snap.trendArrow` / `context.arrow`) AT LEAST ONCE somewhere in the file,
    /// proving the real CGM trend arrow was never deleted alongside the band glyph. This is a presence
    /// check ONLY — see `everyRenderBlockRendersItsTrendArrowAtMostOnce` below for the uniqueness prong
    /// (WR-01: the two together give "exactly once per render occasion," which a single whole-file
    /// `contains` can't express since several pinned surfaces legitimately render the trend arrow once
    /// EACH across multiple independent regions/families). Loud-not-vacuous: scanned count == 3.
    @Test func everyPinnedSurfaceStillRendersItsTrendToken() throws {
        let repoRoot = try #require(Self.repoRootURL(),
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

        #expect(missing.isEmpty,
                "Trend-arrow regression:\n\(missing.joined(separator: "\n"))")
        #expect(scanned == 3,
                "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)")
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
        let repoRoot = try #require(Self.repoRootURL(),
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
                    violations.append("\(path): render block starting '\(firstLine.trimmingCharacters(in: .whitespaces))' renders the trend arrow \(count) times (expected at most 1)")
                }
            }
        }

        #expect(violations.isEmpty,
                "Duplicate trend-arrow render:\n\(violations.joined(separator: "\n"))")
        #expect(scanned == 3,
                "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)")
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
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        var scanned = 0
        var missing: [String] = []

        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            scanned += 1
            let hasZoneWord = stripped.contains(Self.zoneWordNeedle)
            let hasAccessibilityAnnotation = stripped.contains("accessibilityLabel(") || stripped.contains("accessibilityValue(")
            if !(hasZoneWord && hasAccessibilityAnnotation) {
                missing.append("\(path) is missing the VoiceOver zone-word cue (needs both '\(Self.zoneWordNeedle)' and an accessibilityLabel(/accessibilityValue( call)")
            }
        }

        #expect(missing.isEmpty,
                "VoiceOver zone-word regression:\n\(missing.joined(separator: "\n"))")
        #expect(scanned == 3,
                "expected to scan all 3 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)")
    }

    /// Loud-not-vacuous plumbing check (mirrors `BandDriftGuardTests.fileResolutionActuallyFoundTheRepoRoot`):
    /// a path-resolution bug must fail loudly, not pass vacuously. Also pins the exact surface count.
    @Test func guardResolvesRepoRootAndScansAllThreeGlucoseSurfaces() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
        #expect(Self.pinnedSurfaces.count == 3,
                "expected exactly 3 pinned glucose surfaces (09.29-DIAGNOSIS.md §A, minus the Mac + Watch + Live Activity surfaces removed by 03-01/03-03/07-01 delete-on-main) — pin list drifted")
        var scannedSurfaces = 0
        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "pinned glucose surface does not exist at \(url.path)")
            guard (try? String(contentsOf: url, encoding: .utf8)) != nil else {
                Issue.record("pinned glucose surface could not be read at \(url.path)")
                continue
            }
            scannedSurfaces += 1
        }
        #expect(scannedSurfaces == 3,
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
            "}",
        ]
        let slice = Self.balancedSlice(startingAt: 0, in: lines)
        #expect(slice.contains("doSomething()"), "expected the slice to include its own nested content")
        #expect(!slice.contains("doOther()"), "expected the slice to stop at its own matching close brace, not spill into the next block")
        #expect(slice.hasPrefix("struct Foo {"), "expected the slice to start at the requested line")
    }
}
