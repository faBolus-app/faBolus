import Testing
import Foundation
@testable import faBolus

/// Every non-exempt `SettingsCatalog` key must appear as a literal in `ios/faBolus/Views`, so a
/// modeled setting cannot become unreachable. `garminTargetApp` is the only debug-menu exemption.
struct SettingsReachabilityGuardTests {
    /// Keys reachable only from the hidden debug menu, exempt from the reachability rule. Keep this
    /// allowlist tiny — anything added here bypasses the scan.
    static let debugExemptKeys: Set<String> = ["garminTargetApp"]

    /// Resolve `ios/faBolus/Views` by walking up from `#filePath`.
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

    /// Recursively enumerate every `.swift` file under `root`, skipping build artifacts. Kept as a
    /// private duplicate so this suite has no cross-file test-target dependency.
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let skipDirNames: Set<String> = [".build", "DerivedData", "Pods", ".git", "node_modules"]
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

    private static func combinedViewsSource() -> (files: [URL], source: String)? {
        guard let viewsDir = viewsDirURL() else { return nil }
        let files = allSwiftFiles(under: viewsDir)
        let source = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return (files, source)
    }

    // MARK: - Every non-exempt catalog key is reachable

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
            #expect(referenced,
                    "\(d.key) has no reachable UI reference under ios/faBolus/Views/ and is not debug-exempt")
        }
    }

    // MARK: - Debug-exempt allowlist never hides a truly-orphaned key

    @Test func debugExemptKeysAreStillReachableSomewhere() throws {
        guard let (files, combinedSource) = Self.combinedViewsSource() else {
            Issue.record("could not resolve ios/faBolus/Views from #filePath=\(#filePath)")
            return
        }
        #expect(!files.isEmpty, "path resolution broke — found zero Views/*.swift files")

        for key in Self.debugExemptKeys {
            let referenced = combinedSource.contains(".\(key)") || combinedSource.contains("\"\(key)\"")
            #expect(referenced,
                    "debug-exempt key \(key) is not referenced anywhere — should be removed, not exempted")
        }
    }
}
