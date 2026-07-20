import SwiftUI

/// Details page: everything the pump reports, matching the phone's details card + Garmin details
/// screen — active insulin, reservoir, battery, CGM, last bolus, carb ratio, correction factor,
/// target, max bolus, and connection.
struct WatchDetailsView: View {
    @Bindable var model: WatchModel

    var body: some View {
        List {
            row("Active insulin", String(format: "%.2f U", model.iobUnits))
            row("Reservoir", "\(Int(model.reservoirUnits)) U")
            row("Pump battery", model.batteryPercent > 0 ? "\(model.batteryPercent)%" : "—")
            row("CGM", model.cgmActive ? "Active" : "Inactive")
            if let lb = model.lastBolusUnits { row("Last bolus", String(format: "%.2f U", lb)) }
            row("Carb ratio", model.carbRatio > 0 ? String(format: "%.0f g/U", model.carbRatio) : "—")
            row("Correction (ISF)", model.isf > 0 ? "\(model.isf)" : "—")
            row("Target", model.targetBg > 0 ? "\(model.targetBg)" : "—")
            row("Max bolus", String(format: "%.1f U", model.maxBolusUnits))
            if !model.connection.isEmpty { row("Pump", model.connection) }
        }
        .navigationTitle("Details")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium) }
            .font(.caption)
    }
}
