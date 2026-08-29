import Testing
import Foundation
@testable import faBolus

/// Sandbox-safe round-trip of the file-write pattern `DebugMenuView` uses to export `diagnosticsText`
/// to a devicectl-pullable file. Writes to `FileManager.default.temporaryDirectory` (NOT the real
/// Documents container) so the test never touches the simulator's actual app sandbox; the writing
/// options mirror `DebugMenuView.writeDiagnosticsExportFile` exactly — the same options literal is what
/// production code must use for the pull to succeed on a device that has been unlocked at least once
/// since boot (`.completeFileProtectionUntilFirstUserAuthentication`, never `.completeFileProtection`).
struct DebugExportTests {
    @Test func diagnosticsExportRoundTripsWithFirstUnlockProtection() throws {
        let text = "faBolus diagnostics (local-only, never uploaded)\nGenerated: sample\n[Pump identity]\nModel: —\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faBolus-diagnostics-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(text.utf8).write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])

        let readBack = try Data(contentsOf: url)
        #expect(String(decoding: readBack, as: UTF8.self) == text)
    }
}
