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
    /// - Parameters:
    ///   - percent: the battery percent (0...100), from `PumpSnapshot.batteryPercent`.
    ///   - charging: the pump's POSITIVELY-reported charging state, from
    ///     `PumpSnapshot.batteryCharging` (fail-closed: `false` for absent/unknown/never-read).
    public static func make(percent: Int, charging: Bool) -> BatteryPresentation {
        let symbol: String
        if charging {
            // Charging always shows the bolt-in-battery glyph, regardless of level.
            symbol = "battery.100percent.bolt"
        } else {
            // Level→glyph mapping — this helper is the ONE place that owns it.
            switch percent {
            case ...5:   symbol = "battery.0"
            case ...37:  symbol = "battery.25"
            case ...62:  symbol = "battery.50"
            case ...87:  symbol = "battery.75"
            default:     symbol = "battery.100"
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
