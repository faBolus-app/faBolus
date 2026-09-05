import Testing
import Foundation
@testable import faBolus

/// Pins that `ios/faBolus/Intents/` stays gone and that no file under `ios/faBolus` OR `Shared`
/// (the app target's second source root, per `project.yml`'s `- path: Shared`) conforms to
/// `AppShortcutsProvider` — i.e. the APP TARGET exposes no Siri/Shortcuts surface.
///
/// This is NOT a blanket "App Intents cannot dose" guarantee, and must not be read as one:
/// `Shared/WidgetBolusIntents.swift` declares the Quick-Bolus widget's App Intents (the 1-2-3
/// confirm flow that hands a dose to the app), is excluded from the app target and compiled into
/// the widget extension — so App Intents ARE a live dose path here. This scan deliberately does
/// not cover it.
struct ShortcutsAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/ShortcutsAbsenceGuardTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
    }

    // MARK: - The whole Intents directory is gone

    @Test func intentsDirectoryIsAbsentFromWorkingTree() {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Intents")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(
            !exists,
            "ios/faBolus/Intents must be absent from narrow main (git rm'd, preserved on dev/siri-shortcuts)")
    }

    // MARK: - No file under ios/faBolus conforms to AppShortcutsProvider (FaBolusShortcuts is fully gone)

    /// Recursively collect every `.swift` file under `ios/faBolus`.
    private static func swiftFiles(under directory: URL) -> [URL] {
        var results: [URL] = []
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        else { return results }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            results.append(fileURL)
        }
        return results
    }

    @Test func noFileUnderIosFaBolusConformsToAppShortcutsProvider() throws {
        let root = Self.repoRoot.appendingPathComponent("ios/faBolus")
        for fileURL in Self.swiftFiles(under: root) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(
                !source.contains("AppShortcutsProvider"),
                "\(fileURL.lastPathComponent) must not conform to AppShortcutsProvider — FaBolusShortcuts is removed in full"
            )
        }
    }

    /// The app target's SECOND source root (`project.yml`'s `- path: Shared`) — widened here so the
    /// "APP TARGET exposes no Siri/Shortcuts surface" invariant actually covers both roots, not just
    /// `ios/faBolus`. Excludes `WidgetBolusIntents.swift`: it deliberately declares the Quick-Bolus
    /// App Intents (a live dose path compiled into the widget extension), per this file's own
    /// header paragraph — scanning it here would be exactly the wrong assertion.
    @Test func noFileUnderSharedConformsToAppShortcutsProviderExceptWidgetBolusIntents() throws {
        let root = Self.repoRoot.appendingPathComponent("Shared")
        for fileURL in Self.swiftFiles(under: root) where fileURL.lastPathComponent != "WidgetBolusIntents.swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(
                !source.contains("AppShortcutsProvider"),
                "\(fileURL.lastPathComponent) must not conform to AppShortcutsProvider — FaBolusShortcuts is removed in full"
            )
        }
    }

    /// A path-resolution bug must fail loudly, not pass vacuously (mirrors the other absence guards'
    /// own `fileResolutionActuallyFound...` sanity check).
    @Test func fileResolutionActuallyFoundTheIosFaBolusDirectory() {
        let root = Self.repoRoot.appendingPathComponent("ios/faBolus")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        #expect(
            exists && isDir.boolValue,
            "boundary test could not locate ios/faBolus — path resolution broke (#filePath=\(#filePath))")
    }

    /// Same anti-vacuity check for the widened `Shared` root — and confirms `WidgetBolusIntents.swift`
    /// itself is actually there to be excluded, not silently absent.
    @Test func fileResolutionActuallyFoundTheSharedDirectoryAndWidgetBolusIntents() {
        let root = Self.repoRoot.appendingPathComponent("Shared")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        #expect(
            exists && isDir.boolValue,
            "boundary test could not locate Shared — path resolution broke (#filePath=\(#filePath))")
        let widgetBolusIntents = root.appendingPathComponent("WidgetBolusIntents.swift")
        #expect(
            FileManager.default.fileExists(atPath: widgetBolusIntents.path),
            "Shared/WidgetBolusIntents.swift must exist — the exclusion in the scan above is vacuous otherwise")
    }
}
