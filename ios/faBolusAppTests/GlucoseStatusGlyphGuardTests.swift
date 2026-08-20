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
struct GlucoseStatusGlyphGuardTests {

    // MARK: - Scan vocabulary

    /// The band-glyph forms this guard forbids inside a glucose surface. Deliberately NOT a bare
    /// `symbolName` string — see file doc comment.
    static let bandGlyphNeedles = [
        "BandIndicator(", "band.symbolName", "band?.symbolName",
    ]

    /// The real CGM trend-arrow tokens that must survive the band-glyph removal — every pinned surface
    /// renders its trend through one of these three forms (09.29-05-PLAN.md Task 2).
    static let trendArrowNeedles = [".trend", "snap.trendArrow", "context.arrow"]

    /// All eight glucose surfaces the D-02 sweep (waves 01-04) touched, pinned BY PATH
    /// (09.29-DIAGNOSIS.md §A table) — the full set this teardown wave's guard now covers.
    static let pinnedSurfaces = [
        "ios/faBolus/Views/StatusRingView.swift",
        "ios/faBolusWidgets/GlucoseLiveActivity.swift",
        "ios/faBolusWidgets/GlucoseWidget.swift",
        "ios/faBolusWidgets/StatusWidget.swift",
        "mac/faBolusMac/MacComponents.swift",
        "mac/faBolusMacWidgets/FaBolusMacWidgetBundle.swift",
        "watch/faBolusWatch/WatchHUDView.swift",
        "watch/faBolusWatchWidgets/GlucoseComplication.swift",
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
    /// technique as `BandDriftGuardTests.balancedSlice`. Not currently exercised by this guard's tests
    /// (whole-file scans suffice for these eight small surface files) but kept here, mirroring the
    /// sibling guard's shape, so a future surface needing block-scoped scanning doesn't have to
    /// reinvent it.
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

    // MARK: - Tests

    /// Prong 1 (glyph-gone): every pinned glucose surface, stripped of comments, must contain none of
    /// `bandGlyphNeedles`. Loud-not-vacuous: asserts the scanned count equals eight — the full pinned
    /// list, not a partial/broken scan.
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
        }

        #expect(violations.isEmpty,
                "Band-glyph regression guard violated:\n\(violations.joined(separator: "\n"))")
        #expect(scanned == 8,
                "expected to scan all 8 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)")
    }

    /// Prong 2 (single-trend-arrow survives): every pinned surface still renders its trend token (one
    /// of `.trend` / `snap.trendArrow` / `context.arrow`) at least once, proving the real CGM trend
    /// arrow was never deleted alongside the band glyph. Loud-not-vacuous: scanned count == 8.
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
        #expect(scanned == 8,
                "expected to scan all 8 pinned glucose surfaces under \(repoRoot.path), scanned \(scanned) — scan broke (would otherwise pass vacuously)")
    }

    /// Loud-not-vacuous plumbing check (mirrors `BandDriftGuardTests.fileResolutionActuallyFoundTheRepoRoot`):
    /// a path-resolution bug must fail loudly, not pass vacuously. Also pins the exact surface count.
    @Test func guardResolvesRepoRootAndScansAllEightGlucoseSurfaces() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
        #expect(Self.pinnedSurfaces.count == 8,
                "expected exactly 8 pinned glucose surfaces (09.29-DIAGNOSIS.md §A) — pin list drifted")
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
        #expect(scannedSurfaces == 8,
                "expected to actually read all 8 pinned glucose surfaces — plumbing broke (would otherwise pass vacuously)")
    }
}
