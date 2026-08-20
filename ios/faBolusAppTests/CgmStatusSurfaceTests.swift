import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.22-05 (Task 2, D-12): pins the PURE view-model behind the unified CGM-status surface —
/// the classification of every CONFIGURED source into `active failover` vs `configured-but-not-selected`
/// (reusing the arbitrated `GlucoseProvenance` the live badge uses), plus the armed-vs-selected
/// distinction (F-18) so a Test against a source that isn't armed yet is never mistaken for the live
/// failover. Mirrors the pure-helper extraction of `CgmCredentialsView.testOutcome` — no SwiftUI view,
/// no live arbitration.
struct CgmStatusSurfaceTests {

    private let configured: [(id: String, name: String)] = [
        (id: "dexcom-g7-ble", name: "Dexcom G7 / ONE+ (direct BLE)"),
        (id: "dexcom-share",  name: "Dexcom Share (cloud, last resort)"),
        (id: "nightscout",    name: "Nightscout (any CGM)"),
    ]

    // MARK: - Classification

    /// When a failover source is live, EXACTLY ONE row is `.activeFailover` (the arbitrated source);
    /// every other configured source is `.configuredNotSelected`.
    @Test func activeFailoverMarksExactlyOneSourceWhenFailoverLive() {
        let rows = CgmStatusView.rows(
            configured: configured,
            selectedId: "dexcom-g7-ble", armedId: "dexcom-g7-ble",
            provenance: .failover(sourceID: "dexcom-g7-ble", reason: .pumpStale),
            armedStatusCaseName: "connected", armedAgeSeconds: 90)

        let active = rows.filter { $0.classification == .activeFailover }
        #expect(active.count == 1, "exactly one source must be the active failover")
        #expect(active.first?.id == "dexcom-g7-ble")
        for r in rows where r.id != "dexcom-g7-ble" {
            #expect(r.classification == .configuredNotSelected,
                    "\(r.id) should be configured-but-not-selected, was \(r.classification)")
        }
    }

    /// When the pump feed is live (no failover), the armed source is `.armedPumpLive`, NOT
    /// `.activeFailover` — nothing is driving a failover, so no row claims to be live.
    @Test func pumpLiveMarksArmedSourceAsArmedPumpLiveNotActive() {
        let rows = CgmStatusView.rows(
            configured: configured,
            selectedId: "dexcom-g7-ble", armedId: "dexcom-g7-ble",
            provenance: .pump,
            armedStatusCaseName: "connected", armedAgeSeconds: 30)

        #expect(rows.first { $0.id == "dexcom-g7-ble" }?.classification == .armedPumpLive)
        #expect(rows.allSatisfy { $0.classification != .activeFailover },
                "with the pump live, no source may be marked active failover")
    }

    /// F-18: a source SELECTED but not yet ARMED (the selection takes effect on relaunch) is shown as
    /// `.selectedNotArmed`, while the still-running OLD source keeps driving failover — so a passing
    /// Test on the newly-selected source is not mistaken for the live feed.
    @Test func selectedButNotYetArmedIsDistinctFromTheLiveArmedSource() {
        let rows = CgmStatusView.rows(
            configured: configured,
            selectedId: "dexcom-share",   // user just picked Share…
            armedId: "dexcom-g7-ble",     // …but G7 is still the running instance until relaunch
            provenance: .failover(sourceID: "dexcom-g7-ble", reason: .pumpStale),
            armedStatusCaseName: "connected", armedAgeSeconds: 60)

        #expect(rows.first { $0.id == "dexcom-share" }?.classification == .selectedNotArmed,
                "the newly-selected-but-unarmed source must read as selected-not-armed (F-18)")
        #expect(rows.first { $0.id == "dexcom-g7-ble" }?.classification == .activeFailover,
                "the still-running source keeps driving the live failover")
    }

    // MARK: - Live status/age attach only to the armed source

    @Test func liveStatusAndAgeAttachOnlyToTheArmedSource() {
        let rows = CgmStatusView.rows(
            configured: configured,
            selectedId: "dexcom-g7-ble", armedId: "dexcom-g7-ble",
            provenance: .pump,
            armedStatusCaseName: "connected", armedAgeSeconds: 120)

        let armed = rows.first { $0.id == "dexcom-g7-ble" }
        #expect(armed?.statusCaseName == "connected")
        #expect(armed?.ageSeconds == 120)
        for r in rows where r.id != "dexcom-g7-ble" {
            #expect(r.statusCaseName == nil, "\(r.id) is not armed — no live status")
            #expect(r.ageSeconds == nil, "\(r.id) is not armed — no live age")
        }
    }

    // MARK: - Redaction + pure formatters

    /// Same redaction discipline as CgmArbiterDiagnostics: `.error(String)` renders only its case name,
    /// never the associated string.
    @Test func errorStatusRedactsToCaseNameOnly() {
        #expect(CgmStatusView.statusCaseName(.error("token expired: bearer abc123")) == "error")
        #expect(CgmStatusView.statusCaseName(.connected) == "connected")
        #expect(CgmStatusView.statusCaseName(.stale) == "stale")
        #expect(CgmStatusView.statusCaseName(.needsSetup) == "needsSetup")
    }

    @Test func classificationLabelsAreDistinctAndActiveIsCallable() {
        let all: [CgmStatusView.Classification] =
            [.activeFailover, .armedPumpLive, .selectedNotArmed, .configuredNotSelected]
        let labels = Set(all.map { CgmStatusView.classificationLabel($0) })
        #expect(labels.count == all.count, "each classification must have a distinct label")
        #expect(CgmStatusView.classificationLabel(.activeFailover).lowercased().contains("active"))
    }

    @Test func rowDetailFormatsAgeAndHandlesNoReading() {
        #expect(CgmStatusView.rowDetail(statusCaseName: "connected", ageSeconds: 45).contains("45s ago"))
        #expect(CgmStatusView.rowDetail(statusCaseName: "connected", ageSeconds: 180).contains("3 min ago"))
        #expect(CgmStatusView.rowDetail(statusCaseName: "searching", ageSeconds: nil).contains("no reading"))
    }

    // MARK: - WR-01/IN-02/IN-03 (09.24 review): shared Section-2/Section-3 subtitle basis
    //
    // `CgmSettingsView.currentSelectionSubtitle` (SettingsView.swift) and `configureAndTestSubtitle`
    // must never disagree about whether a source is selected for the same underlying state. Before
    // the fix, Section 3 read the raw, unvalidated `GlucoseSourceRegistry.selectedId()` while
    // Section 2 validated against `GlucoseSourceRegistry.selected()` — so a stale/invalid persisted
    // id made the two sections contradict each other. These tests exercise the shared pure helper
    // both call sites now go through, `CgmStatusView.selectionStatusSubtitle`, directly — no live
    // view, no live `AppModel`.

    /// The core WR-01 regression: a `nil` selection (what `GlucoseSourceRegistry.selected()` returns
    /// both for "nothing chosen" AND for a stale/invalid persisted id) must read as "not selected" —
    /// the same family of message Section 2's `configureAndTestSubtitle` shows for `nil` — and must
    /// NEVER render as "Selected —" text, regardless of what a stale armed/provenance state claims.
    @Test func selectionStatusSubtitleNeverContradictsNotSelectedForANilOrStaleSelection() {
        let result = CgmStatusView.selectionStatusSubtitle(
            selected: nil,
            armedId: "healthkit",   // stale: still "armed" per old state, but no longer selectable
            provenance: .failover(sourceID: "healthkit", reason: .pumpStale))

        #expect(result.text == "Pump only — no failover source selected")
        #expect(!result.text.localizedCaseInsensitiveContains("selected —"),
                "a nil (stale/invalid) selection must never render as 'Selected — …' — the WR-01 contradiction")
        #expect(result.isActive == false)
    }

    @Test func selectionStatusSubtitleReflectsActiveFailoverForAValidSelection() {
        let result = CgmStatusView.selectionStatusSubtitle(
            selected: (id: "dexcom-g7-ble", name: "Dexcom G7 / ONE+ (direct BLE)"),
            armedId: "dexcom-g7-ble",
            provenance: .failover(sourceID: "dexcom-g7-ble", reason: .pumpStale))

        #expect(result.text == CgmStatusView.classificationLabel(.activeFailover))
        #expect(result.isActive == true)
    }

    /// F-18: a selected-but-not-yet-armed source must read as "Selected — reopen the app to arm",
    /// distinct from both the active-failover and the nil/not-selected cases above.
    @Test func selectionStatusSubtitleReflectsSelectedNotArmed() {
        let result = CgmStatusView.selectionStatusSubtitle(
            selected: (id: "dexcom-share", name: "Dexcom Share (cloud, last resort)"),
            armedId: "dexcom-g7-ble",
            provenance: .failover(sourceID: "dexcom-g7-ble", reason: .pumpStale))

        #expect(result.text == CgmStatusView.classificationLabel(.selectedNotArmed))
        #expect(result.isActive == false)
    }
}
