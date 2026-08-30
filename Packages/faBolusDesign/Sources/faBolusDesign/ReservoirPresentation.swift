import Foundation

/// The pure presentation result `ReservoirPresentation.make` returns.
public struct ReservoirDisplay: Equatable, Sendable {
    /// The SINGLE formatted display string every reservoir-rendering surface should consume —
    /// `"142 U"` for a reported reading, `"—"` when the pump has never reported one.
    public let valueText: String
    /// Whether the pump has actually reported a reading. `false` ⇒ `valueText` is the unknown
    /// placeholder and the surface should render it in a de-emphasised/neutral treatment rather than as
    /// live data.
    public let isKnown: Bool
}

/// SINGLE source of truth for how a reservoir reading is displayed, including the ABSENT case. Pure and
/// host-agnostic — no SwiftUI/UIKit — so it is trivially unit-testable and the status pill, the details
/// card, the widgets and the Debug menu all get byte-identical treatment.
///
/// Added for debug session `tslim-reservoir-battery-zero`. `PumpSnapshot.reservoirUnits` is a
/// non-optional `Double` defaulting to `0`, so a read that was never answered (op-36 had been durably
/// excluded on the owner's brand-new t:slim X2) rendered as a confident `0 U` on every surface — each of
/// which had hand-rolled its own `String(format: "%.0f U", …)`. An empty cartridge is a clinically
/// meaningful state, so absence must never be able to imitate it, and the test for "is this real?" must
/// live in exactly one place.
public enum ReservoirPresentation {
    /// What every surface shows when a pump-sourced value has never been reported. An EM DASH, matching
    /// `PumpDetailsCard`'s existing unknown treatment for `carbRatio`/`isf`/`targetBg`.
    public static let unknownText = "—"

    /// - Parameter units: `PumpSnapshot.reservoirUnitsIfRead` — the units the pump reported, or `nil`
    ///   when it has never answered the reservoir read. Pass the `…IfRead` funnel, never the raw
    ///   `reservoirUnits`, or the absent case collapses back into `0 U`.
    public static func make(units: Double?) -> ReservoirDisplay {
        guard let units else { return ReservoirDisplay(valueText: unknownText, isKnown: false) }
        return ReservoirDisplay(valueText: String(format: "%.0f U", units), isKnown: true)
    }
}
