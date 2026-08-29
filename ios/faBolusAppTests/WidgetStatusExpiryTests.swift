import Testing
import Foundation
@testable import faBolus

/// Pins that a stuck `.delivering` widget status older than the TTL surfaces `.expired` with request
/// identity preserved, not `.idle`. Collapsing to idle would re-present the 1-2-3 pad as a safe
/// retry while the original dose outcome is still unknown.
///
/// `.serialized` + own-keys-only cleanup: this suite writes the REAL shared App-Group
/// `UserDefaults(suiteName:)`, so never `removePersistentDomain` — it would clobber the other
/// suites that bind the same container.
@Suite(.serialized)
struct WidgetStatusExpiryTests {

    private static var suite: UserDefaults { UserDefaults(suiteName: WidgetStore.appGroup)! }
    private static func clearStatus() { suite.removeObject(forKey: "wbStatus") }

    // MARK: - Stale, unconsumed ".delivering" surfaces the explicit expired/unknown state

    @Test func staleUnconsumedDeliveringSurfacesExpiredNotIdle() {
        Self.clearStatus()
        defer { Self.clearStatus() }
        let staleAt = Date().addingTimeInterval(-(WidgetBolusStore.deliveringExpiryTTL + 5))
        WidgetBolusStore.setStatus(
            WidgetBolusStatus(
                phase: .delivering, units: 2.5,
                requestId: "cxf09-stale", updatedAt: staleAt))
        let status = WidgetBolusStore.status()
        #expect(status.phase == .expired)  // NOT .idle
        #expect(status.requestId == "cxf09-stale")  // identity preserved
        #expect(status.units == 2.5)  // dose amount preserved
    }

    /// The synthesized `.expired` status must not read as a confirmed, safe outcome, nor as a
    /// one-tap-safe retry — asserted at the state level via the message it carries.
    @Test func expiredStatusIsNotPresentedAsASafeRetry() {
        Self.clearStatus()
        defer { Self.clearStatus() }
        let staleAt = Date().addingTimeInterval(-(WidgetBolusStore.deliveringExpiryTTL + 30))
        WidgetBolusStore.setStatus(
            WidgetBolusStatus(
                phase: .delivering, units: 1.0,
                requestId: "cxf09-retry-check", updatedAt: staleAt))
        let status = WidgetBolusStore.status()
        #expect(status.phase == .expired)
        // Must read as "verify before acting," not as a green light to dose again.
        #expect(status.message.lowercased().contains("unknown"))
        #expect(!status.message.lowercased().contains("safe"))
        #expect(!status.message.lowercased().contains("retry"))
    }

    // MARK: - A fresh, in-window ".delivering" is still shown as delivering

    @Test func freshDeliveringIsNotPrematurelyExpired() {
        Self.clearStatus()
        defer { Self.clearStatus() }
        WidgetBolusStore.setStatus(
            WidgetBolusStatus(
                phase: .delivering, units: 3.0,
                requestId: "cxf09-fresh", updatedAt: Date()))
        let status = WidgetBolusStore.status()
        #expect(status.phase == .delivering)
        #expect(status.requestId == "cxf09-fresh")
    }

    @Test func deliveringJustUnderTheExpiryWindowIsStillDelivering() {
        Self.clearStatus()
        defer { Self.clearStatus() }
        let almostStale = Date().addingTimeInterval(-(WidgetBolusStore.deliveringExpiryTTL - 5))
        WidgetBolusStore.setStatus(
            WidgetBolusStatus(
                phase: .delivering, units: 1.5,
                requestId: "cxf09-almost", updatedAt: almostStale))
        #expect(WidgetBolusStore.status().phase == .delivering)
    }

    // MARK: - Terminal statuses keep their existing short revert-to-idle behavior, unaffected

    @Test func terminalStatusesStillRevertToIdleAfterFifteenSeconds() {
        Self.clearStatus()
        defer { Self.clearStatus() }
        for phase: WidgetBolusPhase in [.delivered, .cancelled, .failed] {
            let staleAt = Date().addingTimeInterval(-20)
            WidgetBolusStore.setStatus(
                WidgetBolusStatus(
                    phase: phase, units: 1.0,
                    requestId: "cxf09-terminal", updatedAt: staleAt))
            #expect(WidgetBolusStore.status().phase == .idle, "\(phase) must still revert to idle, unchanged")
        }
    }

    @Test func freshTerminalStatusIsStillShownAsIs() {
        Self.clearStatus()
        defer { Self.clearStatus() }
        WidgetBolusStore.setStatus(
            WidgetBolusStatus(
                phase: .delivered, units: 2.0, deliveredUnits: 2.0,
                requestId: "cxf09-fresh-done", updatedAt: Date()))
        let status = WidgetBolusStore.status()
        #expect(status.phase == .delivered)
        #expect(status.deliveredUnits == 2.0)
    }
}
