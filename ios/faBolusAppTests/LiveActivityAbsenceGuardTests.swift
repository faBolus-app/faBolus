import Testing
import Foundation
@testable import faBolus

/// Pins that no production file under `ios/` references `ActivityKit` (except `AppModel.swift`
/// doc comments) and that `App.swift` does not reference `LiveActivityIntentBridge`.
struct LiveActivityAbsenceGuardTests {

    /// Resolve the repo root by walking up from `#filePath` until `project.yml` is found.
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

    /// Recursively enumerate production `.swift` files under `ios/`, skipping build artifacts,
    /// `*Tests` directories, and `AppModel.swift` (remaining Live Activity mentions there are
    /// doc-comment prose).
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
                "ActivityKit regression — the following production files still reference ActivityKit:\n\(violations.joined(separator: "\n"))")
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
                "App.swift must not reference LiveActivityIntentBridge — the Live Activity bridge install is removed")
    }
}
