import SwiftUI
import faBolusCore

/// modern HUD status row: Active Insulin (IOB), reservoir, battery, and CGM pills.
/// (COB/"Active Carbs" was removed — the pump doesn't expose a carbs-on-board read.)
struct StatusPillsView: View {
    let snapshot: PumpSnapshot

    var body: some View {
        HStack(spacing: 10) {
            pill(icon: "drop.fill", tint: AppTheme.insulin,
                 value: String(format: "%.2f U", snapshot.iobUnits), label: "Active Insulin")
            pill(icon: "cross.vial.fill", tint: .teal,
                 value: String(format: "%.0f U", snapshot.reservoirUnits), label: "Reservoir")
        }
        // CGM pill shows the reading's age and turns warning-colored when stale (self-updating).
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            HStack(spacing: 10) {
                pill(icon: batteryIcon(snapshot.batteryPercent),
                     tint: snapshot.batteryPercent <= 20 ? AppTheme.low : .green,
                     value: "\(snapshot.batteryPercent)%", label: "Pump")
                cgmPill(now: ctx.date)
            }
        }
    }

    @ViewBuilder private func cgmPill(now: Date) -> some View {
        let active = snapshot.cgmActive
        let stale = GlucoseFreshness.isStale(snapshot.glucoseDate, now: now)
        let value: String = snapshot.glucoseDate.map { GlucoseFreshness.ageLabel(for: $0, now: now) }
            ?? (active ? "OK" : "—")
        let tint: Color = !active ? .gray : (stale && snapshot.glucose != nil ? AppTheme.low : AppTheme.inRange)
        pill(icon: active ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward",
             tint: tint, value: value, label: "CGM")
    }

    /// SF Symbol whose fill level tracks the battery percentage.
    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ...5:   return "battery.0"
        case ...37:  return "battery.25"
        case ...62:  return "battery.50"
        case ...87:  return "battery.75"
        default:     return "battery.100"
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
