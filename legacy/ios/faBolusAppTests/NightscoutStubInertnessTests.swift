import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that the Nightscout upload/backfill surface — `NightscoutUploader`, `NightscoutBackfill`,
/// `nightscoutUploadEnabled`, the `onNightscoutSync` coordinator seam — and `maybeBackfillNightscout`/
/// `lastNSBackfill` all stay deleted from `AppModel`, not merely renamed or re-gated. A half-live
/// Nightscout path would put network I/O and UserDefaults dose markers back on main.
@MainActor
struct NightscoutStubInertnessTests {

    /// Source-level proof that the whole Nightscout surface is gone from AppModel, not merely renamed
    /// or re-gated.
    @Test func nightscoutSurfaceIsAbsentFromAppModel() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot =
            testFileURL
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
        let appModelURL = repoRoot.appendingPathComponent("ios/faBolus/Data/AppModel.swift")
        let source = try String(contentsOf: appModelURL, encoding: .utf8)
        #expect(source.count > 200, "AppModel.swift resolved implausibly short — path resolution likely broke")

        // Declaration-SHAPED patterns, not bare substrings — a deletion's own explanatory comment can
        // legitimately NAME a deleted symbol in prose to document what was removed and why; a bare
        // `source.contains("lastNSBackfill")` would false-positive on such a comment. Matching the exact
        // declaration/call shape sidesteps that.
        let deletedDeclarations = [
            "func maybeBackfillNightscout(", "var lastNSBackfill",
            "onNightscoutSync", "NightscoutUploader.shared.sync("
        ]
        for declaration in deletedDeclarations {
            #expect(
                !source.contains(declaration),
                "'\(declaration)' still present in AppModel.swift; the Nightscout surface must be DELETED, not merely gated"
            )
        }
    }

    /// The stub file itself is gone, and no production source anywhere re-declares the Nightscout
    /// upload/backfill symbols.
    @Test func nightscoutStubFileAndSymbolsAreAbsentFromProductionSource() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot =
            testFileURL
            .deletingLastPathComponent()  // → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
        let stubURL = repoRoot.appendingPathComponent("ios/faBolus/Data/CGM/Sources/NightscoutStub.swift")
        #expect(
            !FileManager.default.fileExists(atPath: stubURL.path),
            "NightscoutStub.swift must not exist on disk — it was deleted outright, not left as a compile shim")

        // Scan production source only (never Tests/, which legitimately names these symbols in prose
        // describing what was removed and why).
        let deletedDeclarations = [
            "class NightscoutUploader", "enum NightscoutBackfill", "var nightscoutUploadEnabled"
        ]
        var scannedFileCount = 0
        for root in ["ios/faBolus", "Shared", "Packages/faBolusCore/Sources"] {
            let rootURL = repoRoot.appendingPathComponent(root)
            guard
                let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)
            else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                scannedFileCount += 1
                for declaration in deletedDeclarations {
                    #expect(
                        !source.contains(declaration),
                        "\(fileURL.lastPathComponent) still declares '\(declaration)' — the Nightscout stub must be deleted"
                    )
                }
            }
        }
        #expect(scannedFileCount > 50, "scan resolved implausibly few files — path resolution likely broke")
    }
}
