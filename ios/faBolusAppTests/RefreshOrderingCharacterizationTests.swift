import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that `AppModel.refresh()` resets therapy params on a pump-switch before merge, then computes
/// safety edges from the pre-assignment snapshot. Final-state assertions cannot catch a reorder that still lands on the same values.
@Suite(.serialized) @MainActor
struct RefreshOrderingCharacterizationTests {

    /// Durable temp `ledgerStoreURL` so the pump-switch `.switched` arm does not return early on
    /// `hasInFlightOrUnresolvedDelivery` — without a store the reset is deferred and the order pin never fires.
    private func makeModel() async -> (AppModel, MockBackend) {
        let s = AppSettings.shared
        s.phoneReadOnly = false
        s.childModeEnabled = false
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("refresh-order-l-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        return (model, backend)
    }

    /// The always-present ordered "spine" of top-level phase + effect tags every `refresh()` emits,
    /// regardless of build flags / runtime gates. Safety-edge tags carry their decision (`":raise"` etc.),
    /// so they are matched by PREFIX. The gated tag (`subscriberFanout` behind `alertsChanged`) is
    /// deliberately NOT in the spine — its presence varies, but the spine's strict subsequence still
    /// constrains WHERE it may appear.
    private static let spine: [String] = [
        "maybeHandlePumpSwitch", "merge", "facadeAssign",
        "connectionEdge:", "freshnessEdge:", "stalenessWatchdog:", "urgentLowEdge:",
        "widgetPublish", "historyPersist",
        "statusPush"
    ]

    /// The subsequence of `recorded` that matches a spine entry (by `==` or prefix), projected back onto
    /// the spine entry it matched — so the result is directly comparable to `spine`.
    private func spineProjection(of recorded: [String]) -> [String] {
        recorded.compactMap { tag in Self.spine.first { tag == $0 || tag.hasPrefix($0) } }
    }

    // MARK: - Scenario 1: top-level order (maybeHandlePumpSwitch → merge → façade-assign → effects)

    @Test func topLevelOrderIsSwitchThenMergeThenFacadeAssignThenEffects() async {
        PumpSwitchStore.clear()
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }
        var recorded: [String] = []
        model.refreshEffectOrderRecorderForTesting = { recorded.append($0) }

        await backend.connect()
        recorded.removeAll()  // isolate exactly one steady-state tick
        backend.seedFreshGlucose(120)  // fires a single `source.onChange` → one `refresh()`

        // The ordering trap: switch-handling strictly before merge, merge strictly before the first façade
        // write, and every safety-edge + effect tag strictly after it.
        #expect(
            Array(recorded.prefix(3)) == ["maybeHandlePumpSwitch", "merge", "facadeAssign"],
            "refresh() must run maybeHandlePumpSwitch → merge → façade-assign as the first three phases")
        // The always-present spine (edges then cross-surface fan-out) appears exactly once each, in order.
        #expect(
            spineProjection(of: recorded) == Self.spine,
            "the top-level phase + effect order must match the pre-extraction sequence exactly")
        // Every emitted tag lands at or after `facadeAssign` except the two phases that precede it.
        let facadeIdx = recorded.firstIndex(of: "facadeAssign")!
        for (i, tag) in recorded.enumerated() where i > facadeIdx {
            #expect(
                tag != "maybeHandlePumpSwitch" && tag != "merge",
                "no phase may run after the first façade write except the effects tail")
        }
    }

    // MARK: - Pump-switch resets therapy params before merge

    /// Asserts `carbRatio`/`isf`/`targetBg` (seeded ≠ default), not `maxBolusUnits` (seed 25 == default).
    /// Without a durable ledger the switch arm defers and this pin would never fire.
    @Test func pumpSwitchResetsTherapyParamsBeforeMergeReadsThem() async {
        PumpSwitchStore.setHandled("real|SOME-OLD-PUMP-UUID")
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }

        // Precondition: the seeded MockBackend snapshot carries the prior pump's therapy params.
        #expect(
            backend.snapshot.carbRatio == 10 && backend.snapshot.isf == 40 && backend.snapshot.targetBg == 110,
            "precondition: the mock seeds a non-default therapy profile")

        await backend.connect()  // a genuine switch (marker says a real pump) → maybeHandlePumpSwitch resets

        #expect(
            PumpSwitchStore.lastHandled() == "sim|mobi",
            "precondition: a genuine pump switch was detected and the marker advanced")
        // The published snapshot (produced by merge, which read source.snapshot AFTER the reset) shows the
        // PumpSnapshot() defaults — proving maybeHandlePumpSwitch mutated source.snapshot before merge.
        #expect(model.snapshot.carbRatio == 0, "carbRatio must be reset to the PumpSnapshot() default before merge")
        #expect(model.snapshot.isf == 0, "isf must be reset to the PumpSnapshot() default before merge")
        #expect(model.snapshot.targetBg == 0, "targetBg must be reset to the PumpSnapshot() default before merge")
    }

    // MARK: - Safety edges computed from the pre-assignment value

    @Test func safetyEdgesAreComputedFromPreAssignmentState() async {
        PumpSwitchStore.clear()
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }
        var recorded: [String] = []
        model.refreshEffectOrderRecorderForTesting = { recorded.append($0) }

        await backend.connect()  // → .connected
        backend.seedFreshGlucose(120, at: Date())  // fresh ⇒ previousGlucoseFresh becomes true

        // Freshness: a fresh→stale transition must RAISE, proving the edge read the PRE-assignment
        // previousGlucoseFresh (== true) rather than this tick's just-computed (false) value.
        recorded.removeAll()
        backend.seedFreshGlucose(120, at: Date().addingTimeInterval(-3600))  // now stale; connection unchanged
        #expect(
            recorded.contains("freshnessEdge:raise"),
            "fresh→stale must RAISE — computed from the pre-assignment previousGlucoseFresh == true")
        #expect(
            recorded.contains("connectionEdge:none"),
            "connection was unchanged (.connected) — the freshness edge raised independently")

        // Connection: a live→disconnected transition must RAISE, proving the edge read the PRE-assignment
        // previousConnection (== .connected) rather than the newly-assigned .disconnected.
        recorded.removeAll()
        backend.disconnect()  // .connected → .disconnected
        #expect(
            recorded.contains("connectionEdge:raise"),
            "live→disconnected must RAISE — computed from the pre-assignment previousConnection == .connected")
    }
}
