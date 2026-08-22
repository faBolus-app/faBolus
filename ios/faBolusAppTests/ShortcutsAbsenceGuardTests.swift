import Testing
import Foundation
@testable import faBolus

/// **FEAT-05 boundary test (Phase 7, 07-03, P-C).** Siri + read-only Shortcuts are removed: the whole
/// `ios/faBolus/Intents/` directory (5 files: `ModeIntents`, `ProfileIntents`, `ShortcutsIntents`,
/// `StatusIntents`, `TempRateIntents`) is `git rm`'d, which removes `struct FaBolusShortcuts:
/// AppShortcutsProvider` (it lived entirely inside `StatusIntents.swift:146` — there was never a
/// separate `App.swift` registration to delete, RESEARCH correction). This suite pins both the
/// directory's absence and the negative — NO `.swift` file anywhere under `ios/faBolus` conforms to
/// `AppShortcutsProvider` — while leaving `Shared/WidgetBolusIntents.swift` (the KEPT Quick-Bolus
/// widget's App Intents, which does not conform to `AppShortcutsProvider` and lives outside
/// `ios/faBolus` entirely) untouched and unreferenced by either check.
///
/// RED-first: this suite FAILS against pre-removal `main` (the 5 files + `FaBolusShortcuts` still
/// exist) — proving it has teeth. GREEN once this task's deletion lands.
///
/// Reuses the raw-text `String(contentsOf:)` scan + `#filePath`-rooted repo-root resolution idiom from
/// `FeatureSurfaceAbsenceGuardTests`/`RetrospectiveAbsenceGuardTests`.
struct ShortcutsAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/ShortcutsAbsenceGuardTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
    }

    // MARK: - The whole Intents directory is gone

    @Test func intentsDirectoryIsAbsentFromWorkingTree() {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Intents")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(!exists,
                "ios/faBolus/Intents must be absent from narrow main (git rm'd, FEAT-05, preserved on dev/siri-shortcuts)")
    }

    // MARK: - No file under ios/faBolus conforms to AppShortcutsProvider (FaBolusShortcuts is fully gone)

    /// Recursively collect every `.swift` file under `ios/faBolus`.
    private static func swiftFiles(under directory: URL) -> [URL] {
        var results: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return results }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            results.append(fileURL)
        }
        return results
    }

    @Test func noFileUnderIosFaBolusConformsToAppShortcutsProvider() throws {
        let root = Self.repoRoot.appendingPathComponent("ios/faBolus")
        for fileURL in Self.swiftFiles(under: root) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!source.contains("AppShortcutsProvider"),
                    "\(fileURL.lastPathComponent) must not conform to AppShortcutsProvider — FaBolusShortcuts is removed in full (FEAT-05)")
        }
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors the other absence guards'
    /// own `fileResolutionActuallyFound...` sanity check).
    @Test func fileResolutionActuallyFoundTheIosFaBolusDirectory() {
        let root = Self.repoRoot.appendingPathComponent("ios/faBolus")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        #expect(exists && isDir.boolValue,
                "boundary test could not locate ios/faBolus — path resolution broke (#filePath=\(#filePath))")
    }
}
