import Testing
import Foundation
@testable import faBolus

/// Phase 09.3 (D-01/D-03, SC2): makes the "no orphaned modeled settings key" rule self-enforcing.
///
/// The pre-GSD UI audit flagged 5 `SettingsCatalog` keys as possibly orphaned (no reachable UI
/// reference). `09.3-RESEARCH.md` verified the flag was stale — all keys are already reachable today
/// (`criticalAlertsEnabled`/`suppressMirroredPumpAlarms` in `AlertRulesView`, `historyRetentionDays` in
/// `DataHistoryView`), except `garminTargetApp`, which is intentionally debug-only (D-03, reachable only
/// via `DebugMenuView`'s hidden 7-tap gesture). So SC2 is satisfied NOW — this suite is the guard that
/// keeps it satisfied as future edits touch the catalog or the Views.
///
/// This is a POSITIVE reachability scan (inverse of `LiveActivityBoundaryTests`' negative delivery-seam
/// scan): it enumerates every `SettingsCatalog.descriptors` key and asserts the combined source text of
/// `ios/faBolus/Views/*.swift` contains a literal reference to it. A plain substring scan is sufficient
/// here — a computed `Binding` (e.g. `AlertRulesView`'s `suppressBinding`) still spells the backing key
/// literally (`settings.suppressMirroredPumpAlarms`) inside its `get`/`set` closures, so this correctly
/// finds guarded bindings too, not just direct `$settings.<key>` bindings. The failure mode to guard
/// against is a false negative (key IS bound but via some indirection that never spells the literal
/// name) — not a false positive — which is why no comment-stripping/precision scanning (as the
/// delivery-seam boundary tests need) is required here.
struct SettingsReachabilityGuardTests {
    /// D-03: keys intentionally reachable ONLY from the hidden debug menu, exempt from the reachability
    /// rule. Keep this allowlist tiny and explicit — anything added here bypasses SC2.
    static let debugExemptKeys: Set<String> = ["garminTargetApp"]

    /// Resolve `ios/faBolus/Views` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/SettingsReachabilityGuardTests.swift`) — same technique as
    /// `LiveActivityBoundaryTests.intentsFileURL()`.
    private static func viewsDirURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("ios/faBolus/Views")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Recursively enumerate every `.swift` file under `root`, skipping build artifacts/test-target
    /// directories. Verbatim copy of `LiveActivityBoundaryTests.allSwiftFiles(under:)` for parity — kept
    /// as a private duplicate (rather than a shared helper) so this suite has no cross-file test-target
    /// dependency.
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let skipDirNames: Set<String> = [".build", "DerivedData", "Pods", ".git", "node_modules"]
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

    private static func combinedViewsSource() -> (files: [URL], source: String)? {
        guard let viewsDir = viewsDirURL() else { return nil }
        let files = allSwiftFiles(under: viewsDir)
        let source = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return (files, source)
    }

    // MARK: - SC2: every non-exempt catalog key is reachable

    @Test func everyNonExemptCatalogKeyIsReachableInViews() throws {
        guard let (files, combinedSource) = Self.combinedViewsSource() else {
            Issue.record("could not resolve ios/faBolus/Views from #filePath=\(#filePath)")
            return
        }
        // A path-resolution bug must fail loudly, not pass vacuously (mirrors
        // LiveActivityBoundaryTests.fileResolutionActuallyFoundTheIntentsFile).
        #expect(!files.isEmpty, "path resolution broke — found zero Views/*.swift files")

        for d in SettingsCatalog.descriptors where !Self.debugExemptKeys.contains(d.key) {
            let referenced = combinedSource.contains(".\(d.key)") || combinedSource.contains("\"\(d.key)\"")
            #expect(
                referenced,
                "\(d.key) has no reachable UI reference under ios/faBolus/Views/ and is not debug-exempt")
        }
    }

    // MARK: - D-03: the debug-exempt allowlist never hides a truly-orphaned key

    @Test func debugExemptKeysAreStillReachableSomewhere() throws {
        guard let (files, combinedSource) = Self.combinedViewsSource() else {
            Issue.record("could not resolve ios/faBolus/Views from #filePath=\(#filePath)")
            return
        }
        #expect(!files.isEmpty, "path resolution broke — found zero Views/*.swift files")

        for key in Self.debugExemptKeys {
            let referenced = combinedSource.contains(".\(key)") || combinedSource.contains("\"\(key)\"")
            #expect(
                referenced,
                "debug-exempt key \(key) is not referenced anywhere — should be removed, not exempted")
        }
    }
}
