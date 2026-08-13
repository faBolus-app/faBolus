import SwiftUI
import faBolusCore

/// Details page: everything the pump reports, matching the phone's details card + Garmin details
/// screen — active insulin, reservoir, battery, CGM, last bolus, carb ratio, correction factor,
/// target, max bolus, and connection.
struct WatchDetailsView: View {
    @Bindable var model: WatchModel

    /// Phase 4 (mmol/L display-unit support) — the unit mirrored from the phone's statusRead reply
    /// (`WatchModel.glucoseDisplayUnit`). ISF/target route through the canonical `GlucoseUnit` funnel,
    /// matching the phone's `PumpDetailsCard` — mg/dL mode renders byte-identical to before this phase.
    private var unit: GlucoseUnit { model.glucoseDisplayUnit }

    var body: some View {
        List {
            // Rows + order mirror the phone's Details customization (model.detailsOrder). "Last bolus"
            // is skipped when there's no value; the connection row is watch-only and always last.
            ForEach(model.detailsOrder, id: \.self) { id in
                if let v = value(id) { row(label(id), v) }
            }
            if !model.connection.isEmpty { row("Pump", model.connection) }
        }
        .navigationTitle("Details")
    }

    private func label(_ id: String) -> String {
        switch id {
        case "iob": return "Active insulin"
        case "reservoir": return "Reservoir"
        case "battery": return "Pump battery"
        case "cgm": return "CGM"
        case "lastBolus": return "Last bolus"
        case "carbRatio": return "Carb ratio"
        case "isf": return "Correction (ISF)"
        case "target": return "Target"
        case "maxBolus": return "Max bolus"
        default: return id
        }
    }
    private func value(_ id: String) -> String? {
        switch id {
        case "iob": return String(format: "%.2f U", model.iobUnits)
        case "reservoir": return "\(Int(model.reservoirUnits)) U"
        case "battery": return model.batteryPercent > 0 ? "\(model.batteryPercent)%" : "—"
        case "cgm": return model.cgmActive ? "Active" : "Inactive"
        case "lastBolus": return model.lastBolusUnits.map { String(format: "%.2f U", $0) }
        case "carbRatio": return model.carbRatio > 0 ? String(format: "%.0f g/U", model.carbRatio) : "—"
        // Phase 4 (D-10): ISF + target render in the received unit; the underlying mg/dL Int
        // (model.isf/model.targetBg) is never converted — this is display-only, matching the phone.
        case "isf":
            guard model.isf > 0 else { return "—" }
            return "\(unit.format(mgdl: model.isf)) \(unit == .mmol ? "mmol/L·U⁻¹" : "mg/dL/U")"
        case "target":
            guard model.targetBg > 0 else { return "—" }
            return "\(unit.format(mgdl: model.targetBg)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
        case "maxBolus": return String(format: "%.1f U", model.maxBolusUnits)
        default: return nil
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium) }
            .font(.caption)
    }
}
