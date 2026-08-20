import Testing
import Foundation
@testable import faBolus

/// **D-05 regression guard, tracer wave (Phase 09.29, Plan 01).** Proves the deletion of the confusing
/// good/bad `BandIndicator` glyph from `StatusRingView` is SELF-ENFORCING going forward, and that the
/// real CGM trend arrow + zone color survive the edit. Modeled directly on `BandDriftGuardTests`'
/// repo-walk-up + loud-not-vacuous idiom (09.29-CONTEXT.md D-05); scoped in this tracer plan to ONE
/// representative surface — `StatusRingView.swift`, which backs both the iOS Main HUD ring and the
/// phone-as-remote — pinned BY PATH. Expansion waves (02-04) generalize this scan to the remaining ~10
/// `BandIndicator` render sites (09.29-DIAGNOSIS.md §A table); the teardown wave (05) widens the surface
/// list to all of them once every call site is gone.
///
/// The scan needles are DELIBERATELY narrow: the shared glyph view's instantiation (`BandIndicator(`)
/// and the glucose band-symbol expression forms (`band.symbolName` / `band?.symbolName`) — NEVER a bare
/// `symbolName` grep. `ClinicianTierAck`/`StoredSettingChange` own an unrelated `symbolName` used in
/// `SettingChangeLogView.swift` and `PumpWizardViews.swift` (name collision); a bare-string needle would
/// false-positive on those and is explicitly disallowed by 09.29-01-PLAN.md's acceptance criteria.
struct GlucoseStatusGlyphGuardTests {

    // MARK: - Scan vocabulary

    /// The band-glyph forms this guard forbids inside a glucose surface. Deliberately NOT a bare
    /// `symbolName` string — see file doc comment.
    static let bandGlyphNeedles = [
        "BandIndicator(", "band.symbolName", "band?.symbolName",
    ]

    /// The real CGM trend-arrow + zone-color calls that must survive the band-glyph removal.
    static let trendArrowNeedle = "Text(snapshot.trend)"
    static let zoneColorNeedle = "AppTheme.glucoseColor("

    /// Representative glucose surfaces this tracer plan scans, pinned BY PATH (not by directory walk)
    /// so the guard's scope is explicit and reviewable. Expansion waves append the remaining
    /// 09.29-DIAGNOSIS.md §A surfaces here as they're swept.
    static let pinnedSurfaces = [
        "ios/faBolus/Views/StatusRingView.swift",
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
    /// technique as `BandDriftGuardTests.balancedSlice`. Not currently exercised by this tracer's
    /// three tests (whole-file scan suffices for a single small view file) but kept here, mirroring
    /// the sibling guard's shape, so expansion waves can adopt block-scoped scanning without
    /// reinventing it if a future surface needs it.
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

    /// RED until the band-glyph block is deleted from `StatusRingView.swift`; GREEN after. Loud-not-
    /// vacuous: asserts at least one surface was actually scanned.
    @Test func statusRingViewHasNoBandGlyph() throws {
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
        #expect(scanned > 0,
                "expected to scan at least one glucose surface under \(repoRoot.path) — scan broke (would otherwise pass vacuously)")
    }

    /// Must stay green both before and after the band-glyph removal — proves the real trend arrow and
    /// zone color are never touched by the deletion.
    @Test func statusRingViewStillRendersOneTrendArrowAndColor() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        var scanned = 0
        var missing: [String] = []

        for path in Self.pinnedSurfaces {
            let url = repoRoot.appendingPathComponent(path)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripLineComments(raw)
            scanned += 1
            if !stripped.contains(Self.trendArrowNeedle) {
                missing.append("\(path) is missing the real trend-arrow call '\(Self.trendArrowNeedle)'")
            }
            if !stripped.contains(Self.zoneColorNeedle) {
                missing.append("\(path) is missing the zone-color call '\(Self.zoneColorNeedle)'")
            }
        }

        #expect(missing.isEmpty,
                "Trend arrow / zone color regression:\n\(missing.joined(separator: "\n"))")
        #expect(scanned > 0,
                "expected to scan at least one glucose surface under \(repoRoot.path) — scan broke (would otherwise pass vacuously)")
    }

    /// Loud-not-vacuous plumbing check (mirrors `BandDriftGuardTests.fileResolutionActuallyFoundTheRepoRoot`):
    /// a path-resolution bug must fail loudly, not pass vacuously.
    @Test func guardResolvesRepoRootAndScansGlucoseSurfaces() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
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
        #expect(scannedSurfaces >= 1,
                "expected to actually read at least one pinned glucose surface — plumbing broke (would otherwise pass vacuously)")
    }
}
