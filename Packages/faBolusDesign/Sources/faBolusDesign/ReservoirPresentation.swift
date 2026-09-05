import Foundation

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
    public static let unknownText = PumpValuePresentation.unknownText

    /// - Parameter units: `PumpSnapshot.reservoirUnitsIfFresh(now:)` — the units the pump reported, or
    ///   `nil` when it has never answered the reservoir read OR has not re-answered it inside the
    ///   staleness window (debug `pump-value-decay-to-unknown`). Pass one of the model's optional
    ///   funnels, never the raw `reservoirUnits`, or the absent case collapses back into `0 U`. The
    ///   presence-only `reservoirUnitsIfRead` is the weaker gate — prefer `…IfFresh` on any surface
    ///   that reads as live data.
    public static func make(units: Double?) -> PumpValueDisplay {
        PumpValuePresentation.make(units, format: "%.0f U")
    }
}
