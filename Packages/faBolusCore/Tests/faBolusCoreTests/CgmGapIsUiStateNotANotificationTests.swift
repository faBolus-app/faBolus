import Testing
import Foundation
@testable import faBolusCore

/// A CGM gap is UI state — never a notification (owner decision, 2026-08-30).
///
/// `.cgmDataLoss` carried BOTH the immediate "CGM data lost" banner and the pre-armed staleness
/// watchdog, and both fire at the same `GlucoseFreshness.staleAfter` threshold (6 min), so the category
/// produced one notification request per advanced CGM datum. The gap already shows as UI state (the
/// greyed CGM pill with its age in the app, the greyed value in the widgets), so the category is now
/// refused at the one governed decision point rather than at any individual poster.
///
/// The boundary this suite defends: refusing `.cgmDataLoss` must NOT silence (a) the app-owned
/// urgent-low backstop, which lives on its own `.urgentLowGlucose` category precisely so it survives
/// this, or (b) a PUMP-raised CGM alert, which arrives on `.pumpAlert` carrying
/// `safetyClass == .cgmDataLoss` and is a different thing entirely.
@Suite struct CgmGapIsUiStateNotANotificationTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func at(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
    }
    private func msg(_ c: C, key: String = "k", severity: B.Severity = .warning) -> B.Message {
        B.Message(category: c, severity: severity, title: "t", body: "b", dedupeKey: key)
    }

    /// `.cgmDataLoss` is the ONLY category that never surfaces as a notification — named exhaustively so
    /// a future category cannot be quietly added to the silent set.
    @Test func cgmDataLossIsTheOnlyCategoryThatNeverSurfacesAsANotification() {
        #expect(!C.cgmDataLoss.deliversAsNotification)
        let silent = Set(C.allCases.filter { !$0.deliversAsNotification }.map(\.rawValue))
        #expect(silent == ["cgmDataLoss"])
    }

    /// `decide()` refuses it regardless of severity and regardless of settings — the immediate banner and
    /// the watchdog both routed through here, so one refusal covers every poster, in-process or not.
    @Test func decideRefusesCgmDataLossAtEverySeverityAndUnderEverySetting() {
        for severity in B.Severity.allCases {
            let d = B.decide(
                msg(.cgmDataLoss, severity: severity),
                settings: [.cgmDataLoss: B.CategorySettings(enabled: true)],
                state: B.State(), now: at(9, 0), calendar: cal)
            #expect(
                !d.deliver && d.reason == .uiStateOnly,
                "a \(severity) .cgmDataLoss must be refused as UI-state-only, not delivered")
        }
    }

    /// Refusing it must not advance the day/meal budget counters — a silent category cannot consume the
    /// budget that gates a genuine `bolusDeliveryFailed`.
    @Test func aRefusedCgmDataLossConsumesNoBudgetAndRecordsNoEpisode() {
        let d = B.decide(
            msg(.cgmDataLoss, key: "safety.cgmDataLoss"), settings: [:],
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!d.deliver)
        #expect(d.nextState.deliveredToday == 0)
        #expect(d.nextState.notifiedEpisodes.isEmpty)
        #expect(d.nextState.lastDeliveredAt["cgmDataLoss"] == nil)
    }

    /// The urgent-low backstop is on its OWN never-suppressible category and still alarms during a gap —
    /// this is the whole reason it was decoupled from `.cgmDataLoss`.
    @Test func theUrgentLowBackstopStillAlarmsDuringACgmGap() {
        #expect(C.urgentLowGlucose.deliversAsNotification)
        let hostile = Dictionary(
            uniqueKeysWithValues: C.allCases.map {
                ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1439))
            })
        let d = B.decide(
            msg(.urgentLowGlucose, severity: .critical), settings: hostile,
            state: B.State(), now: at(3, 0), calendar: cal)
        #expect(d.deliver, "the urgent-low backstop must survive the CGM-gap policy change")
    }

    /// A PUMP-raised CGM alert is a `.pumpAlert` carrying `safetyClass == .cgmDataLoss` — a different
    /// channel that must keep notifying (and keep breaking through Focus/DND).
    @Test func aPumpRaisedCgmAlertStillNotifiesAndStillBreaksThrough() {
        let pumpCgm = B.Message(
            category: .pumpAlert, severity: .warning, title: "CGM unavailable", body: "b",
            dedupeKey: "pumpalert-3-48", safetyClass: .cgmDataLoss)
        let d = B.decide(
            pumpCgm, settings: [.pumpAlert: B.CategorySettings(enabled: true)],
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(d.deliver, "the pump's own CGM alert is not the app's CGM-gap banner — it must still notify")
        #expect(B.requiresBreakthrough(pumpCgm))
    }

    /// The other four never-suppressible categories are untouched: still delivered under a hostile config.
    @Test func everyOtherNeverSuppressibleCategoryStillAlwaysDelivers() {
        let hostile = Dictionary(
            uniqueKeysWithValues: C.allCases.map {
                ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1439))
            })
        var delivered: Set<String> = []
        for c in C.allCases where c.neverSuppressible && c.deliversAsNotification {
            let d = B.decide(
                msg(c, key: c.rawValue), settings: hostile,
                state: B.State(), now: at(3, 0), calendar: cal)
            if d.deliver { delivered.insert(c.rawValue) }
        }
        #expect(delivered == ["pumpDisconnect", "bolusReconciliation", "pumpConnectionUnstable", "urgentLowGlucose"])
    }
}
