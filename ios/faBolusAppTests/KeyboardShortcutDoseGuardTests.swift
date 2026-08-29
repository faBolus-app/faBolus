import Testing
import Foundation
@testable import faBolus

/// `.keyboardShortcut` must never appear in BolusEntryView: a hardware key must never reach a
/// bolus, delivery, suspend, resume, or cancel action.
struct KeyboardShortcutDoseGuardTests {
    /// Resolve a repo-relative path by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/KeyboardShortcutDoseGuardTests.swift`) — same technique as
    /// `DiagnosticsGatingGuardTests.resolve(_:)` / `SettingsReachabilityGuardTests.viewsDirURL()`.
    private static func resolve(_ relativePath: String) -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - `.keyboardShortcut` never on the dose surface

    @Test func bolusEntryViewNeverGainsAKeyboardShortcut() throws {
        guard let url = Self.resolve("ios/faBolus/Views/BolusEntryView.swift") else {
            Issue.record("could not resolve ios/faBolus/Views/BolusEntryView.swift from #filePath=\(#filePath)")
            return
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            !source.contains("keyboardShortcut"),
            "D-08 violated — BolusEntryView.swift must never contain .keyboardShortcut (a hardware key must never reach a dose action)"
        )
    }

    // MARK: - A path-resolution bug must fail loudly, not pass vacuously

    @Test func fileResolutionActuallyFoundBolusEntryView() {
        #expect(Self.resolve("ios/faBolus/Views/BolusEntryView.swift") != nil)
    }
}
