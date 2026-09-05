import Foundation

/// The pure presentation result `PumpValuePresentation.make` returns.
public struct PumpValueDisplay: Equatable, Sendable {
    /// The SINGLE formatted display string the surface should consume — the formatted number for a
    /// reported reading, the unknown placeholder when the pump has never reported one.
    public let valueText: String
    /// Whether the pump has actually reported a reading. `false` ⇒ `valueText` is the unknown
    /// placeholder and the surface should de-emphasise it (grey tint, no warning colour) rather than
    /// draw it as live data.
    public let isKnown: Bool
}

/// SINGLE source of truth for rendering ANY optional pump-sourced number, including the ABSENT case.
/// Pure and host-agnostic (no SwiftUI/UIKit), so it is trivially unit-testable and every surface — status
/// pill, details card, widget, Debug menu — gets byte-identical treatment for "the pump never told us".
///
/// This is the generalisation of `ReservoirPresentation` (which stays as the reservoir-specific
/// `"%.0f U"` funnel and forwards to this type). It exists because the reservoir/battery
/// fix from debug session `tslim-reservoir-battery-zero` was not the only instance of the defect: the
/// follow-up app-wide sweep found `iobUnits` and `basalRateUnitsPerHour` doing the same thing — a
/// non-optional, zero-defaulted pump value rendered as a confident number on every surface — each with
/// its own hand-rolled `String(format:)` at the call site.
///
/// The rule this type enforces: **absence and zero are different facts.** `0.00 U` of active insulin,
/// `0.00 U/hr` of basal (a suspend, or a 0 U/hr temp rate) and an empty cartridge are all legitimate,
/// clinically meaningful readings and MUST still render as `0`. Only a value we do not have renders as
/// the placeholder.
///
/// Pass one of the model's optional funnels, never the raw non-optional field — the raw field collapses
/// the absent case straight back into a fabricated `0`. Two kinds of funnel exist and they answer
/// different questions:
///   • `…IfRead` (`PumpSnapshot.iobUnitsIfRead`, `basalRateUnitsPerHourIfRead`) — "did the pump EVER
///     report this". Keeps returning a value forever after one reply.
///   • `…IfFresh(now:)` (`PumpSnapshot.reservoirUnitsIfFresh(now:)`, `batteryPercentIfFresh(now:)`) —
///     "is that report still CURRENT". Strictly stronger; prefer it on any surface that reads as live
///     data (debug `pump-value-decay-to-unknown`).
public enum PumpValuePresentation {
    /// What every surface shows when a pump-sourced value has never been reported. One literal, owned
    /// here; the reservoir- and battery-specific funnels read it from this general type.
    public static let unknownText = "—"

    /// - Parameters:
    ///   - value: the pump's reported number, or `nil` when it has never reported one. Pass a
    ///     `PumpSnapshot.…IfRead` funnel.
    ///   - format: the `String(format:)` pattern for the KNOWN case, e.g. `"%.2f U"` for active insulin
    ///     or `"%.2f U/hr"` for a basal rate. Kept at the call site because the unit and the precision are
    ///     a property of the field, not of the absent/present decision this type owns.
    public static func make(_ value: Double?, format: String) -> PumpValueDisplay {
        guard let value else { return PumpValueDisplay(valueText: unknownText, isKnown: false) }
        return PumpValueDisplay(valueText: String(format: format, value), isKnown: true)
    }

    /// Convenience for surfaces that only need the string (a plain text row with no tint to pick).
    /// Same contract as `make`; kept so those call sites don't have to name an unused `isKnown`.
    public static func text(_ value: Double?, format: String) -> String {
        make(value, format: format).valueText
    }
}
