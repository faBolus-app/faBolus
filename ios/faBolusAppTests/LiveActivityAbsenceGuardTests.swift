import Testing
import Foundation
@testable import faBolus

/// Pins that no production file under `ios/` or `Shared/` references `ActivityKit` (except
/// `AppModel.swift` doc comments), that `App.swift` does not reference `LiveActivityIntentBridge`,
/// and that the two `Shared/` Live-Activity sources stay deleted.
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

    /// Recursively enumerate production `.swift` files under `ios/` AND `Shared/`, skipping build
    /// artifacts, `*Tests` directories, and `AppModel.swift` (remaining Live Activity mentions there
    /// are doc-comment prose). `Shared/` is in scope because the app target includes it wholesale
    /// (`project.yml`: `- path: Shared`), so a file dropped there compiles into the shipping app.
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let skipDirNames: Set<String> = [".build", "DerivedData", "Pods", "node_modules"]
        let excludedFiles: Set<String> = ["AppModel.swift"]
        var results: [URL] = []
        for treeName in ["ios", "Shared"] {
            let treeRoot = root.appendingPathComponent(treeName)
            guard
                let enumerator = fm.enumerator(
                    at: treeRoot, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
            else { continue }
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
        }
        return results
    }

    // MARK: - ABSENCE: no ActivityKit-driven surface outside DOSE_PATHS/tests/build

    @Test func noProductionFileOutsideAppModelReferencesActivityKit() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
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

        #expect(
            violations.isEmpty,
            "ActivityKit regression — the following production files still reference ActivityKit:\n\(violations.joined(separator: "\n"))"
        )
        #expect(
            scanned > 0,
            "scanned no files under ios/ or Shared/ — path resolution broke (#filePath=\(#filePath)); this guard would otherwise pass vacuously"
        )
    }

    // MARK: - ABSENCE: the two Shared/ Live-Activity sources stay deleted

    /// `Shared/LiveActivityIntents.swift` contains no `ActivityKit` reference, so the content scan
    /// above cannot see it — and the app target compiles all of `Shared/` (`project.yml`:
    /// `- path: Shared`, excluding only `WidgetBolusIntents.swift`). A filename pin is therefore the
    /// only thing standing between `main` and a re-added Live-Activity dose surface. Both files are
    /// preserved on `dev/live-activity`.
    @Test func sharedLiveActivitySourceFilesAreAbsent() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        for relative in ["Shared/LiveActivityShared.swift", "Shared/LiveActivityIntents.swift"] {
            let url = repoRoot.appendingPathComponent(relative)
            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "\(relative) must stay absent — all of Shared/ compiles into the app target")
        }
    }

    // MARK: - ABSENCE: App.swift no longer installs the LiveActivityIntentBridge

    @Test func appSwiftNoLongerReferencesLiveActivityIntentBridge() throws {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent("ios/faBolus/App.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            !source.contains("LiveActivityIntentBridge"),
            "App.swift must not reference LiveActivityIntentBridge — the Live Activity bridge install is removed")
    }
}
