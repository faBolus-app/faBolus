import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.24-01 (D-01/D-02/D-03): pins the unified `CgmSettingsView` "1. Choose a source →
/// 2. Configure & test → 3. Status" guided progression (Task 1), the honest ordering that moves
/// "Nightscout upload" / "Glucose staleness" below the three numbered steps, and the read-only
/// "Last test result" echo added to `CgmStatusView` (Task 3). Mirrors the `#filePath`-rooted
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
            #expect(Self.readSource(path) != nil,
                    "path resolution broke: could not read \(path) from #filePath=\(#filePath)")
        }
    }

    // MARK: - Task 1: numbered section headers + footers

    @Test func numberedSectionHeadersArePresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("1. Choose a source"))
        #expect(source.contains("2. Configure & test"))
        #expect(source.contains("3. Status"))
    }

    @Test func section2FooterIsPresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("Enter credentials for the selected source (if it needs any) and confirm it can get a reading."))
    }

    @Test func section3FooterIsPresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("See live status, freshness, and the last test result for every configured source."))
    }

    // MARK: - Task 1: Section-2 / Section-3 subtitle strings

    @Test func section2SubtitleStringsArePresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("Not selected — pick a source in step 1"))
        #expect(source.contains("Selected: "))
    }

    @Test func section3NoSelectionSubtitleIsPresent() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("Pump only — no failover source selected"))
    }

    @Test func section3SubtitleReusesThePureStatusHelpers() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("CgmStatusView.classificationLabel("))
        #expect(source.contains("CgmStatusView.classify("))
    }

    // MARK: - Task 1: row labels stay byte-identical

    @Test func rowLabelsAreUnchanged() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        #expect(source.contains("CGM credentials & testing"))
        #expect(source.contains("CGM source status"))
    }

    // MARK: - Task 1: ordering — "3. Status" before "Nightscout upload" before "Glucose staleness"

    @Test func statusSectionComesBeforeNightscoutBeforeStaleness() throws {
        let source = try #require(Self.readSource(Self.settingsViewPath))
        guard let statusIdx = source.range(of: "3. Status")?.lowerBound,
              let nightscoutIdx = source.range(of: "Nightscout upload")?.lowerBound,
              let stalenessIdx = source.range(of: "Glucose staleness")?.lowerBound else {
            Issue.record("could not locate all three markers in SettingsView.swift")
            return
        }
        #expect(statusIdx < nightscoutIdx,
                "\"3. Status\" must come before \"Nightscout upload\" in CgmSettingsView's body")
        #expect(nightscoutIdx < stalenessIdx,
                "\"Nightscout upload\" must come before \"Glucose staleness\" in CgmSettingsView's body")
    }

    // MARK: - Task 3: status-page "Last test result" echo

    @Test func lastTestResultSectionHeaderAndFooterArePresent() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(source.contains("Last test result"))
        #expect(source.contains("A read-only echo of the most recent Test you ran on the CGM credentials & testing page. This page never re-runs the test itself."))
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

    /// D-03: the status page is a deliberately passive read — it must never trigger the Test flow.
    @Test func statusViewNeverTriggersStartCgmTest() throws {
        let source = try #require(Self.readSource(Self.statusViewPath))
        #expect(!source.contains("startCgmTest"),
                "CgmStatusView must not reference startCgmTest — the Test action stays on the Configure page (D-03)")
    }
}
