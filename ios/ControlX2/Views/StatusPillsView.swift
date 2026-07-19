import SwiftUI

/// Loop-style HUD status row: Active Insulin (IOB), Active Carbs (COB), reservoir, battery,
/// and CGM pills.
struct StatusPillsView: View {
    let snapshot: PumpSnapshot

    var body: some View {
        HStack(spacing: 10) {
            pill(icon: "drop.fill", tint: LoopTheme.insulin,
                 value: String(format: "%.2f U", snapshot.iobUnits), label: "Active Insulin")
            pill(icon: "fork.knife", tint: LoopTheme.carbs,
                 value: "\(Int(snapshot.cobGrams)) g", label: "Active Carbs")
        }
        HStack(spacing: 10) {
            pill(icon: "cross.vial.fill", tint: .teal,
                 value: String(format: "%.0f U", snapshot.reservoirUnits), label: "Reservoir")
            pill(icon: "battery.75", tint: snapshot.batteryPercent < 20 ? LoopTheme.low : .green,
                 value: "\(snapshot.batteryPercent)%", label: "Pump")
            pill(icon: snapshot.cgmActive ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward",
                 tint: snapshot.cgmActive ? LoopTheme.inRange : .gray,
                 value: snapshot.cgmActive ? "OK" : "—", label: "CGM")
        }
    }

    private func pill(icon: String, tint: Color, value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
