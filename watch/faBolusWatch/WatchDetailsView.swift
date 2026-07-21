import SwiftUI
import faBolusCore

/// Details page: everything the pump reports, matching the phone's details card + Garmin details
/// screen — active insulin, reservoir, battery, CGM, last bolus, carb ratio, correction factor,
/// target, max bolus, and connection.
struct WatchDetailsView: View {
    @Bindable var model: WatchModel

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
        case "isf": return model.isf > 0 ? "\(model.isf)" : "—"
        case "target": return model.targetBg > 0 ? "\(model.targetBg)" : "—"
        case "maxBolus": return String(format: "%.1f U", model.maxBolusUnits)
        default: return nil
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium) }
            .font(.caption)
    }
}
