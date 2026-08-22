import Testing
import Foundation
@testable import faBolus

/// D-08 (09.17-05): `.keyboardShortcut` must NEVER appear in BolusEntryView.swift — a
/// per-file exclusion (simpler to source-scan-guard than an action-name denylist), per
/// UI-SPEC §9's own recommendation. The hard rule this guard makes self-enforcing: no
/// hardware keyboard/pointer input channel may ever reach a bolus/delivery/suspend/resume/
/// cancel action, and `.keyboardShortcut` is the one API that wires a hardware key directly
/// to a SwiftUI action — so it is banned outright from this dose surface, even for
/// non-destructive buttons on the screen (e.g. Cancel/dismiss), keeping the boundary crisp
/// (UI-SPEC §9).
///
/// Phase 9 (09-02, MOBI-02): `PumpControlView.swift` — the other dose surface this guard
/// used to pin — is deleted outright (its sole entry point, the Settings "Advanced control"
/// Section, is removed in the same plan; every `caps.supportsX` gate inside it was already
/// always-false on the t:slim-only capability model, so nothing there was ever reachable).
/// This guard now scopes to `BolusEntryView.swift` only; there is no second file left to scan.
///
/// Mirrors `DiagnosticsGatingGuardTests`' `#filePath`-rooted `resolve()` + raw-text
/// `String(contentsOf:)` scan idiom exactly (RESEARCH.md D-08 source-scan-guard sketch,
/// Pitfall 6 — scanning raw text is robust to whitespace variance and doesn't require
/// parsing Swift syntax).
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

    // MARK: - D-08: the per-file `.keyboardShortcut` exclusion on both dose surfaces

    @Test func bolusEntryViewNeverGainsAKeyboardShortcut() throws {
        guard let url = Self.resolve("ios/faBolus/Views/BolusEntryView.swift") else {
            Issue.record("could not resolve ios/faBolus/Views/BolusEntryView.swift from #filePath=\(#filePath)")
            return
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("keyboardShortcut"),
                "D-08 violated — BolusEntryView.swift must never contain .keyboardShortcut (a hardware key must never reach a dose action)")
    }

    // MARK: - A path-resolution bug must fail loudly, not pass vacuously

    @Test func fileResolutionActuallyFoundBolusEntryView() {
        #expect(Self.resolve("ios/faBolus/Views/BolusEntryView.swift") != nil)
    }
}
