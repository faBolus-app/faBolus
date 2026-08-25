import Testing
import Foundation
@testable import faBolus

/// Phase 17 Plan 03 (D1-05/D3-02, D1-04) — pins two source-level safety-copy facts by scanning
/// production source directly (Swift Testing `@Suite`/`@Test`, mirroring `RegulatoryCopyTests`'s
/// keyword-presence style and `BandDriftGuardTests`'s repo-root-walk-up + file-read idiom):
///
/// 1. **Draft-marker absence (D1-05/D3-02).** `NotificationSettingsView.swift`'s three safety-disable
///    consent dialogs (`.pumpDisconnect`/`.cgmDataLoss`/`.bolusReconciliation`) must no longer carry the
///    internal, now-stale clinical-review draft-marker prefix ("§13-DRAFT — pending Phase 10 clinical
///    review") — §13 is recorded cleared (ROADMAP Phase 11: "✓ Completed 2026-08-23 via owner-accepted
///    AI-panel review"), so the marker is both leaked internal process jargon and factually stale. This
///    is a negative scan: the substantive plain-English consequence sentences are NOT touched by this
///    assertion — only the marker's absence is pinned.
/// 2. **First-run regulatory framing presence (D1-04).** `ConnectPumpOnboardingView.swift` must reference
///    `RegulatoryCopy.firstRun` (owner-signed-off 2026-08-09) so a first-time user sees the
///    experimental/not-FDA-cleared framing on the actual first-run screen, not just in About.
///
/// Both assertions read the file's raw text via `String(contentsOf:)` — a source-scan, not a runtime
/// render — so this suite runs on the xctest host with zero pump/BLE dependency (mirrors
/// `BandDriftGuardTests`'s host-agnostic idiom, not `RegulatoryCopyTests`'s in-memory string check, since
/// this needs to see the SOURCE literal, not the compiled `RegulatoryCopy.firstRun` value).
@Suite struct SafetyCopyGuardTests {

    /// The exact internal clinical-review draft-marker prefix to negative-scan for (17-RESEARCH.md "Code
    /// Examples → Existing safety-copy §13-DRAFT string to strip", verbatim as currently authored in
    /// `NotificationSettingsView.swift:363-372`).
    static let staleDraftMarker = "§13-DRAFT — pending Phase 10 clinical review"

    /// Resolve the repo root by walking up from `#filePath` until `project.yml` is found — same
    /// walk-up technique as `BandDriftGuardTests.repoRootURL()`.
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

    private static func sourceText(relativeTo root: URL, path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func notificationSettingsViewNoLongerCarriesStaleDraftMarker() throws {
        guard let root = Self.repoRootURL() else {
            Issue.record("SafetyCopyGuardTests could not resolve repo root — scan would pass vacuously")
            return
        }
        let source = try Self.sourceText(relativeTo: root, path: "ios/faBolus/Views/NotificationSettingsView.swift")
        #expect(!source.isEmpty, "NotificationSettingsView.swift read as empty — scan would pass vacuously")
        #expect(!source.contains(Self.staleDraftMarker),
                "NotificationSettingsView.swift still carries the stale clinical-review draft-marker prefix (§13 is recorded cleared — this is leaked internal process jargon, D1-05/D3-02)")
    }

    @Test func connectPumpOnboardingViewSurfacesFirstRunRegulatoryCopy() throws {
        guard let root = Self.repoRootURL() else {
            Issue.record("SafetyCopyGuardTests could not resolve repo root — scan would pass vacuously")
            return
        }
        let source = try Self.sourceText(relativeTo: root, path: "ios/faBolus/Views/ConnectPumpOnboardingView.swift")
        #expect(!source.isEmpty, "ConnectPumpOnboardingView.swift read as empty — scan would pass vacuously")
        #expect(source.contains("RegulatoryCopy.firstRun"),
                "ConnectPumpOnboardingView.swift does not surface RegulatoryCopy.firstRun — the first-run experimental/not-FDA-cleared framing is missing from the actual first-run screen (D1-04)")
    }
}
