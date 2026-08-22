import Testing
import Foundation
@testable import faBolus

/// **FEAT-01 boundary test (Phase 7, 07-01, P-A).** The glucose Live Activity (widget-extension
/// views + the app-target lifecycle manager + the shared model/intents + the settings surface + the
/// intent-bridge install) is a CLEAN delete-on-main removal (D-01/D-02) — no dose-set stub required
/// (AppModel.swift's remaining LA references are prose inside doc comments, a documented D-03
/// exception — see `AppModel.swift`'s own doc comments near `snoozeGateAllows`/
/// `autoReconnectIfNeeded`). This UNGATED suite is the permanent regression guard replacing the 9
/// deleted LA test files: it proves (a) no `.swift` file under `ios/` references the literal string
/// `ActivityKit`, outside test files, build artifacts, and `AppModel.swift` (the one documented
/// byte-identity-protected exception), and (b) `App.swift` no longer references
/// `LiveActivityIntentBridge`.
///
/// Reuses the repo-wide `.swift` enumerator idiom from `BandDriftGuardTests.allSwiftFiles(under:)`
/// (itself modeled on the now-deleted `LiveActivityBoundaryTests.allSwiftFiles(under:)`), scoped to
/// `ios/` per the plan's own acceptance criterion, with a single-file exclusion for `AppModel.swift`
/// instead of a whole-package skip (RESEARCH "Don't Hand-Roll").
struct LiveActivityAbsenceGuardTests {

    // MARK: - Repo enumeration (mirrors BandDriftGuardTests' idiom)

    /// Resolve the repo root by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/LiveActivityAbsenceGuardTests.swift`) until `project.yml` — a
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

    /// Recursively enumerate every production `.swift` file under `ios/`, skipping build artifacts,
    /// any `*Tests` directory, and the ONE documented byte-identity-protected exception
    /// (`ios/faBolus/Data/AppModel.swift` — its remaining LA references are prose inside doc
    /// comments, D-03). `.skipsHiddenFiles` already drops dotfile dirs (`.git`, `.build`, `.claude`,
    /// `.gsd`).
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let iosRoot = root.appendingPathComponent("ios")
        let fm = FileManager.default
        let skipDirNames: Set<String> = [".build", "DerivedData", "Pods", "node_modules"]
        let excludedFiles: Set<String> = ["AppModel.swift"]
        guard let enumerator = fm.enumerator(at: iosRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipDirNames.contains(name) || name.hasSuffix("Tests") {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "swift" && !excludedFiles.contains(name) {
                results.append(url)
            }
        }
        return results
    }

    // MARK: - ABSENCE: no ActivityKit-driven surface outside DOSE_PATHS/tests/build

    @Test func noProductionFileOutsideAppModelReferencesActivityKit() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        var scanned = 0
        var violations: [String] = []

        for url in Self.allSwiftFiles(under: repoRoot) {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if source.contains("ActivityKit") {
                let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                violations.append(relative)
            }
        }

        #expect(violations.isEmpty,
                "ActivityKit regression — the glucose Live Activity was removed (FEAT-01) but the following files still reference ActivityKit:\n\(violations.joined(separator: "\n"))")
        #expect(scanned > 0,
                "scanned no files under ios/ — path resolution broke (#filePath=\(#filePath)); this guard would otherwise pass vacuously")
    }

    // MARK: - ABSENCE: App.swift no longer installs the LiveActivityIntentBridge

    @Test func appSwiftNoLongerReferencesLiveActivityIntentBridge() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent("ios/faBolus/App.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("LiveActivityIntentBridge"),
                "App.swift must not reference LiveActivityIntentBridge — the FEAT-01 bridge install is removed")
    }

    // MARK: - ABSENCE: the 5 LA source files are gone from the working tree

    @Test func liveActivitySourceFilesAreAbsentFromWorkingTree() {
        guard let repoRoot = Self.repoRootURL() else {
            Issue.record("could not resolve repo root from #filePath=\(#filePath)")
            return
        }
        let removedRelativePaths = [
            "ios/faBolusWidgets/GlucoseLiveActivity.swift",
            "ios/faBolusWidgets/FullBleedGlucosePlot.swift",
            "Shared/LiveActivityShared.swift",
            "Shared/LiveActivityIntents.swift",
            "ios/faBolus/Data/GlucoseLiveActivityManager.swift",
        ]
        for relative in removedRelativePaths {
            let url = repoRoot.appendingPathComponent(relative)
            #expect(!FileManager.default.fileExists(atPath: url.path),
                    "\(relative) must be absent from narrow main (git rm'd, FEAT-01, preserved on dev/live-activity)")
        }
    }
}
