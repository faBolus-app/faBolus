import Testing
import Foundation
@testable import faBolus

/// Phase 5 (05-04-PLAN.md, Task 2) — the PURE adaptive-layout composer,
/// `LiveActivityComposer.compose(selection:state:region:)` (D-17a). No ActivityKit I/O; every case
/// here is a plain injected `ContentState` + selection + region, so the priority-order/overflow/
/// connection-when-stale/empty-fallback rules are unit-testable without a device (05-RESEARCH.md §
/// Environment Availability). See 05-UI-SPEC.md's Surface Inventory & Layout Contract for the
/// per-region rules this exercises.
struct LiveActivityFieldSelectionTests {

    /// Builds a `ContentState` with only the fields `compose` actually reads (`connected`/
    /// `pumpLinkStale`) parameterized; everything else is a harmless default.
    private func state(connected: Bool = true, pumpLinkStale: Bool = false) -> FaBolusGlucoseAttributes.ContentState {
        FaBolusGlucoseAttributes.ContentState(connected: connected, pumpLinkStale: pumpLinkStale)
    }

    // MARK: Priority order + overflow (whole-field drop, never mid-glyph)

    /// A region's capacity caps the result at the FIRST N ids in the selection's own order — the
    /// composer never reorders, and it drops the LOWEST-priority (tail) ids on overflow.
    @Test func composePreservesSelectionOrderAndDropsOverflowByPriority() {
        // connected: false → "connection" passes its own visibility rule too, so all 7 ids are
        // eligible and the region capacity alone determines what's dropped.
        let s = state(connected: false, pumpLinkStale: true)
        let selection = ["glucose", "iob", "reservoir", "battery", "basal", "controlIQ", "connection"]
        let result = LiveActivityComposer.compose(selection: selection, state: s, region: .expanded)
        #expect(result.map(\.id) == ["glucose", "iob", "reservoir", "battery", "basal"])   // capacity 5, priority order
    }

    /// A capacity-1 region (compact/minimal/CarPlay `.small`) always yields exactly the single
    /// highest-priority selected field.
    @Test func capacityOneRegionYieldsOnlyTheTopPriorityField() {
        let s = state()
        let selection = ["basal", "glucose", "iob"]
        #expect(LiveActivityComposer.compose(selection: selection, state: s, region: .compactLeading).map(\.id) == ["basal"])
        #expect(LiveActivityComposer.compose(selection: selection, state: s, region: .minimal).map(\.id) == ["basal"])
        #expect(LiveActivityComposer.compose(selection: selection, state: s, region: .carPlaySmall).map(\.id) == ["basal"])
    }

    /// The roomiest surface (Lock Screen) never drops anything short of the full 7-id vocabulary.
    @Test func lockScreenCapacityHoldsEveryRealisticSelectionWithoutDropping() {
        let s = state()
        let selection = ["glucose", "iob", "basal", "reservoir", "battery"]
        #expect(LiveActivityComposer.compose(selection: selection, state: s, region: .lockScreen).map(\.id) == selection)
    }

    // MARK: "connection" — visible ONLY when the pump link is down/stale

    /// A fresh, connected link filters "connection" out of the composition entirely — it must never
    /// render as a redundant "all fine" confirmation (pump-surface research §2c).
    @Test func connectionIsFilteredOutWhenLinkIsFreshAndConnected() {
        let s = state(connected: true, pumpLinkStale: false)
        let result = LiveActivityComposer.compose(selection: ["connection"], state: s, region: .lockScreen)
        #expect(result.map(\.id) == ["minimal"])   // nothing else was selected → empty-selection fallback
    }

    /// A down/stale link surfaces "connection" like any other selected field.
    @Test func connectionSurfacesWhenLinkIsDownOrStale() {
        let down = state(connected: false, pumpLinkStale: false)
        #expect(LiveActivityComposer.compose(selection: ["connection"], state: down, region: .lockScreen).map(\.id) == ["connection"])

        let stale = state(connected: true, pumpLinkStale: true)
        #expect(LiveActivityComposer.compose(selection: ["connection"], state: stale, region: .lockScreen).map(\.id) == ["connection"])
    }

    /// "connection" mixed with other fields: filtered out when fresh, the REST of the selection still
    /// composes normally (the filter drops one id, not the whole selection).
    @Test func connectionFilterDoesNotSuppressOtherSelectedFields() {
        let fresh = state(connected: true, pumpLinkStale: false)
        let result = LiveActivityComposer.compose(
            selection: ["glucose", "connection", "iob"], state: fresh, region: .expanded)
        #expect(result.map(\.id) == ["glucose", "iob"])
    }

    // MARK: Empty-selection fallback — never literally nothing

    /// A completely empty selection (0 fields, including glucose) falls back to the synthetic
    /// "minimal" pseudo-field, on every region.
    @Test func emptySelectionFallsBackToMinimalOnEveryRegion() {
        let s = state()
        for region: LARegion in [.compactLeading, .compactTrailing, .minimal, .expanded, .lockScreen, .carPlaySmall] {
            #expect(LiveActivityComposer.compose(selection: [], state: s, region: region).map(\.id) == ["minimal"],
                    "region \(region) did not fall back to minimal")
        }
    }

    /// "glucose" alone (0 pump fields selected, glucose ON — 05-UI-SPEC.md Copywriting Contract)
    /// composes to the glucose chip alone, never triggering the minimal fallback.
    @Test func glucoseAloneComposesToGlucoseNotTheMinimalFallback() {
        let s = state()
        #expect(LiveActivityComposer.compose(selection: ["glucose"], state: s, region: .lockScreen).map(\.id) == ["glucose"])
    }

    // MARK: `.bottom` — the Sparkline slot, gated on "glucose" being selected (D-08)

    @Test func bottomRegionReturnsSparklineOnlyWhenGlucoseIsSelected() {
        let s = state()
        #expect(LiveActivityComposer.compose(selection: ["glucose", "iob"], state: s, region: .bottom).map(\.id) == ["sparkline"])
        #expect(LiveActivityComposer.compose(selection: ["iob", "basal"], state: s, region: .bottom) == [])
        #expect(LiveActivityComposer.compose(selection: [], state: s, region: .bottom) == [])
    }

    // MARK: Pump-only subset (glucose explicitly deselected) — the Task-4 checkpoint's case (3)

    @Test func pumpOnlySubsetWithGlucoseDeselectedComposesTheirPumpFieldsWithoutAGlucoseFallback() {
        let s = state()
        let selection = ["iob", "basal", "reservoir"]
        let result = LiveActivityComposer.compose(selection: selection, state: s, region: .lockScreen)
        #expect(result.map(\.id) == selection)
        #expect(!result.contains(LAField(id: "glucose")))
        #expect(!result.contains(LAField(id: "minimal")))
    }
}
