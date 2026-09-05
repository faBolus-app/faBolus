import Testing
import Foundation

/// Imported HealthKit history is display-only and must never enter the signed dose path, or
/// anywhere else in the app — the surface itself was deleted, so its symbols must never come back.
/// Widened repo-wide after `AppModel+HealthKit.swift` — the only declarer of both forbidden
/// symbols — was removed: a four-file dose-path-only scan would otherwise pass vacuously forever,
/// proving nothing about the rest of the tree. This suite is a KEEP, not a candidate for deletion.
struct HealthKitImportDosePathGuardTests {

    /// Resolve the repo root by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/HealthKitImportDosePathGuardTests.swift`) — same technique as
    /// `LoopInsightsExclusionGuardTests.appDirURL()`.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Packages/faBolusCore/Sources/faBolusCore/BolusMath.swift")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Repo-wide scan roots relative to the repo root — strictly stronger than the old four-file
    /// dose-path-only scan this replaces.
    private static let topLevelScanRootRelativePaths: [String] = ["ios", "Shared"]

    /// `Packages/*/Sources`, resolved dynamically since package names vary and are not worth hardcoding.
    private static func packageSourcesRoots(under root: URL) -> [URL] {
        let fm = FileManager.default
        let packagesDir = root.appendingPathComponent("Packages")
        guard let entries = try? fm.contentsOfDirectory(at: packagesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return
            entries
            .map { $0.appendingPathComponent("Sources") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    /// Every `.swift` file under `root`, recursively — excluding THIS test file itself, whose own
    /// `forbiddenSymbols` literals would otherwise self-match (the same self-match hazard
    /// `NightscoutStubInertnessTests` documents for declaration-shaped needles).
    private static func swiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            if url.lastPathComponent == "HealthKitImportDosePathGuardTests.swift" { continue }
            results.append(url)
        }
        return results
    }

    private static func allScannedSwiftFiles() throws -> [URL] {
        let root = try #require(
            Self.repoRootURL(),
            "could not resolve the repo root from #filePath=\(#filePath)")
        var files: [URL] = []
        for relative in Self.topLevelScanRootRelativePaths {
            files += Self.swiftFiles(under: root.appendingPathComponent(relative))
        }
        for sourcesRoot in Self.packageSourcesRoots(under: root) {
            files += Self.swiftFiles(under: sourcesRoot)
        }
        return files
    }

    /// The forbidden HealthKit import/export symbols. Both were declared ONLY in the now-deleted
    /// `AppModel+HealthKit.swift`.
    private static let forbiddenSymbols = ["HealthKitHistoryImporter", "HealthKitExporter"]

    @Test func repoWideScanResolvesAPlausibleNumberOfFiles() throws {
        let files = try Self.allScannedSwiftFiles()
        #expect(
            files.count > 100,
            "repo-wide scan resolved implausibly few files (\(files.count)) — path resolution likely broke")
    }

    /// Non-vacuity: proves the scan mechanism can actually surface a positive match, by scanning for a
    /// symbol known to exist under the scanned roots. If this ever fails, the file-walk itself is
    /// broken — not evidence that the codebase changed.
    @Test func scanMechanismFindsAKnownPresentSymbol() throws {
        let files = try Self.allScannedSwiftFiles()
        var found = false
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if source.contains("enum BolusMath") {
                found = true
                break
            }
        }
        #expect(
            found,
            "scan mechanism failed to find a known-present symbol ('enum BolusMath') anywhere under the scanned roots — the file walk is broken, not the codebase"
        )
    }

    @Test func noHealthKitImportExportSymbolsExistAnywhereRepoWide() throws {
        let files = try Self.allScannedSwiftFiles()
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for symbol in Self.forbiddenSymbols {
                #expect(
                    !source.contains(symbol),
                    "forbidden HealthKit import/export symbol '\(symbol)' found in \(url.path). The HealthKit surface was deleted; this symbol must never be reintroduced anywhere in the app."
                )
            }
        }
    }
}
