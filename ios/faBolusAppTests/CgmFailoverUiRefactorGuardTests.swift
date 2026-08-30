import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins the unified `CgmSettingsView` "1. Choose a source →
/// 2. Configure & test → 3. Status" guided progression, the honest ordering that moves
/// "Nightscout upload" / "Glucose staleness" below the three numbered steps, and the read-only
/// "Last test result" echo in `CgmStatusView`. Mirrors the `#filePath`-rooted
/// `repoRootURL()` / `readSource` source-scan idiom already used by `DexcomG6CopyGuardTests` /
/// `CgmConfigSectionCopyGuardTests` — no simulator, no live view, pure text-content + source-position
/// guard.
struct CgmFailoverUiRefactorGuardTests {

    // MARK: - Source resolution (mirrors DexcomG6CopyGuardTests.repoRootURL)

    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Shared")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static let settingsViewPath = "ios/faBolus/Views/SettingsView.swift"
    private static let statusViewPath = "ios/faBolus/Views/CgmStatusView.swift"

    /// Vacuous-pass guard: fail loudly if either source file cannot be resolved from `#filePath`,
    /// rather than silently passing every other `#expect` below because the read source is empty.
    @Test func sourceFilesResolveFromFilePath() throws {
        for path in [Self.settingsViewPath, Self.statusViewPath] {
            #expect(
                Self.readSource(path) != nil,
                "path resolution broke: could not read \(path) from #filePath=\(#filePath)")
        }
    }

    // MARK: - Numbered section headers + footers

    @Test func numberedSectionHeadersArePresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("1. Choose a source"))
        #expect(source.contains("2. Configure & test"))
        #expect(source.contains("3. Status"))
    }

    @Test func section2FooterIsPresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(
            source.contains(
                "Enter credentials for the selected source (if it needs any) and confirm it can get a reading."))
    }

    @Test func section3FooterIsPresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("See live status, freshness, and the last test result for every configured source."))
    }

    // MARK: - Section-2 / Section-3 subtitle strings

    @Test func section2SubtitleStringsArePresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("Not selected — pick a source in step 1"))
        #expect(source.contains("Selected: "))
    }

    /// The "no selection" copy lives at its single source of
    /// truth — the shared `CgmStatusView.selectionStatusSubtitle` pure helper — rather than being
    /// duplicated as a literal in `SettingsView.swift`'s Section-3 subtitle. Pin it there instead.
    @Test func section3NoSelectionSubtitleIsPresent() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(source.contains("Pump only — no failover source selected"))
    }

    /// Section 3 calls ONE shared helper
    /// (`CgmStatusView.selectionStatusSubtitle`) instead of calling `classify`/`classificationLabel`
    /// directly and independently from `statusSubtitleColor` (the duplication that let the two
    /// subtitles diverge unnoticed). Assert `SettingsView.swift` reuses that single helper, and that the
    /// helper itself is still built on the pure `classify`/`classificationLabel` primitives rather
    /// than reimplementing the classification logic inline.
    @Test func section3SubtitleReusesThePureStatusHelpers() throws {
        let settingsSource = try #require(Self.readSource(Self.settingsViewPath))
        #expect(settingsSource.contains("CgmStatusView.selectionStatusSubtitle("))
        let statusSource = try #require(Self.readSource(Self.statusViewPath))
        #expect(statusSource.contains("classify(sourceId:"))
        #expect(statusSource.contains("classificationLabel(cls)"))
    }

    // MARK: - Row labels stay byte-identical

    @Test func rowLabelsAreUnchanged() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("CGM credentials & testing"))
        #expect(source.contains("CGM source status"))
    }

    // MARK: - Ordering — "3. Status" before "Glucose staleness"
    //
    // The "Nightscout upload" section this test also ordered is not in narrow
    // `main` — see dev/nightscout's REINTEGRATION.md. The remaining
    // "3. Status" → "Glucose staleness" ordering guard still applies.

    @Test func statusSectionComesBeforeStaleness() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        // Header-specific markers (`Text("…")`) to avoid matching the unrelated
        // `SettingsIndex.entries` "Glucose staleness" keyword string, which appears earlier in the file.
        guard let statusIdx = source.range(of: "Text(\"3. Status\")")?.lowerBound,
            let stalenessIdx = source.range(of: "Text(\"Glucose staleness\")")?.lowerBound
        else {
            Issue.record("could not locate both header markers in SettingsView.swift")
            return
        }
        #expect(
            statusIdx < stalenessIdx,
            "\"3. Status\" must come before \"Glucose staleness\" in CgmSettingsView's body")
    }

    // MARK: - Status-page "Last test result" echo

    @Test func lastTestResultSectionHeaderAndFooterArePresent() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(source.contains("Last test result"))
        #expect(
            source.contains(
                "A read-only echo of the most recent Test you ran on the CGM credentials & testing page. This page never re-runs the test itself."
            ))
    }

    @Test func lastTestResultNeverTestedCopyIsPresent() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(source.contains("No test has been run yet — run **Test** on the CGM credentials & testing page."))
    }

    @Test func lastTestResultWaitingCopyIsPresent() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(source.contains("Test in progress — waiting for a reading from"))
    }

    @Test func lastTestResultSuccessCopyIsPresent() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(source.contains("last test succeeded"))
    }

    @Test func lastTestResultTimeoutCopyIsPresent() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(source.contains("last test found no reading"))
    }

    /// The status page is a deliberately passive read — it must never trigger the Test flow.
    @Test func statusViewNeverTriggersStartCgmTest() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(
            !source.contains("startCgmTest"),
            "CgmStatusView must not reference startCgmTest — the Test action stays on the Configure page")
    }
}
