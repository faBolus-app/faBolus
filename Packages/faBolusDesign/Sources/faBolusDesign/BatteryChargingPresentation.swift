import Foundation

/// The pure presentation result `BatteryChargingPresentation.make` returns: the glyph, whether a
/// "Charging" status should show, and whether the low-battery warning tint applies. Every
/// battery-rendering surface consumes this SAME value instead of re-deriving its own charging
/// treatment, so the decision can never drift between surfaces.
public struct BatteryPresentation: Equatable, Sendable {
    /// SF Symbol name for the battery glyph.
    public let symbolName: String
    /// Whether the "Charging" status text should be shown alongside the battery percent.
    public let showsChargingText: Bool
    /// Whether the low-battery warning tint (e.g. `AppTheme.low`) should apply. Charging ALWAYS
    /// overrides this — charging is never shown as a warning state — so this is `false`
    /// whenever `charging` is `true`, regardless of `percent`.
    public let usesLowTint: Bool
    /// The SINGLE formatted display string ("N%" or "N% · Charging") every battery-rendering surface
    /// should consume instead of re-interpolating its own copy of this text. Equal to
    /// `showsChargingText ? "\(percent)% · Charging" : "\(percent)%"`.
    public let valueText: String
}

/// SINGLE source of truth for the battery-charging glyph/text/tint decision. Pure and
/// host-agnostic — no SwiftUI/UIKit — so it is trivially unit-testable and every consumer (status
/// pill, widgets, Mac, remote) gets byte-identical treatment.
public enum BatteryChargingPresentation {
    /// What the battery shows when the pump hasn't reported it, or the report has aged out: never a level.
    public static let unknownText = "—"

    /// - Parameters:
    ///   - percent: the battery percent (0...100), from `PumpState.battery`.
    ///   - charging: the pump's POSITIVELY-reported charging state, from `PumpBattery.isCharging`
    ///     (fail-closed: pass `false` for absent/unknown/never-read).
    /// ABSENT-reading overload. `percent: nil` ⇒ the pump has never reported a battery level, so nothing
    /// about the level may be asserted: the value text is the unknown placeholder, the low-battery
    /// warning tint is OFF, and the glyph is explicitly NOT `battery.0` (which asserts a dead battery).
    ///
    /// Added for debug session `tslim-reservoir-battery-zero`: a battery percent that reads `0` when the
    /// pump never answered op-144 makes a fully-charged pump render as `0%` with the EMPTY-battery glyph
    /// and the low-battery tint. Pass `PumpState.batteryIfFresh(now:)?.percent` (or the widget carrier's
    /// `batteryPercentIfFresh(asOf:)`), and on any surface that reads as live data never the
    /// presence-only `PumpState.battery?.value`, which keeps returning a value forever once a single
    /// reply has landed.
    public static func make(percent: Int?, charging: Bool) -> BatteryPresentation {
        guard let percent else {
            return BatteryPresentation(
                // A question mark can't be mistaken for a level; every battery-shaped glyph can.
                symbolName: "questionmark.circle",
                // Charging is derived from the same op-145 frame that carries the percent, so with no
                // frame there is no charging claim either (`batteryCharging` is already fail-closed).
                showsChargingText: false,
                usesLowTint: false,
                valueText: unknownText)
        }
        return make(percent: percent, charging: charging)
    }

    public static func make(percent: Int, charging: Bool) -> BatteryPresentation {
        let symbol: String
        if charging {
            // Charging always shows the bolt-in-battery glyph, regardless of level.
            symbol = "battery.100percent.bolt"
        } else {
            // Level→glyph mapping — this helper is the ONE place that owns it.
            switch percent {
            case ...5: symbol = "battery.0"
            case ...37: symbol = "battery.25"
            case ...62: symbol = "battery.50"
            case ...87: symbol = "battery.75"
            default: symbol = "battery.100"
            }
        }
        return BatteryPresentation(
            symbolName: symbol,
            showsChargingText: charging,
            // Charging OVERRIDES the low-battery warning color — never a warning state while
            // charging, even at a low percent.
            usesLowTint: percent <= 20 && !charging,
            valueText: charging ? "\(percent)% · Charging" : "\(percent)%")
    }
}
