import SwiftUI
import faBolusCore

/// modern HUD status row: Active Insulin (IOB), reservoir, battery, and CGM pills.
/// (COB/"Active Carbs" was removed — the pump doesn't expose a carbs-on-board read.)
struct StatusPillsView: View {
    let snapshot: PumpSnapshot
    private var order: [String] { AppSettings.shared.pillsOrder }
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        // Wrapped in a TimelineView so the CGM pill's age label stays current. Pills shown + order
        // come from AppSettings.pillsOrder (Settings → Customize dashboard pills).
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(order, id: \.self) { id in pillFor(id, now: ctx.date) }
            }
        }
    }

    @ViewBuilder private func pillFor(_ id: String, now: Date) -> some View {
        switch id {
        case "iob":
            pill(icon: "drop.fill", tint: AppTheme.insulin,
                 value: String(format: "%.2f U", snapshot.iobUnits), label: "Active Insulin")
        case "reservoir":
            pill(icon: "cross.vial.fill", tint: .teal,
                 value: String(format: "%.0f U", snapshot.reservoirUnits), label: "Reservoir")
        case "battery":
            pill(icon: batteryIcon(snapshot.batteryPercent),
                 tint: snapshot.batteryPercent <= 20 ? AppTheme.low : .green,
                 value: "\(snapshot.batteryPercent)%", label: "Pump")
        case "cgm":
            cgmPill(now: now)
        case "basal":
            if snapshot.deliverySuspended {
                pill(icon: "pause.circle.fill", tint: AppTheme.low, value: "Suspended", label: "Delivery")
            } else {
                pill(icon: "waveform.path.ecg", tint: AppTheme.insulin,
                     value: String(format: "%.2f U/hr", snapshot.basalRateUnitsPerHour), label: "Basal")
            }
        case "controlIQ":
            pill(icon: controlIQIcon, tint: snapshot.controlIQEnabled ? AppTheme.inRange : .gray,
                 value: controlIQValue, label: "Control-IQ")
        case "lastBolus":
            pill(icon: "drop.triangle.fill", tint: AppTheme.insulin,
                 value: snapshot.lastBolusUnits.map { String(format: "%.2f U", $0) } ?? "—", label: "Last bolus")
        case "carbRatio":
            pill(icon: "fork.knife", tint: .orange,
                 value: snapshot.carbRatio > 0 ? String(format: "%.0f g/U", snapshot.carbRatio) : "—", label: "Carb ratio")
        case "isf":
            pill(icon: "arrow.down.right.circle", tint: .purple,
                 value: snapshot.isf > 0 ? "\(snapshot.isf)" : "—", label: "ISF")
        case "target":
            pill(icon: "target", tint: AppTheme.inRange,
                 value: snapshot.targetBg > 0 ? "\(snapshot.targetBg)" : "—", label: "Target")
        case "maxBolus":
            pill(icon: "gauge.with.dots.needle.67percent", tint: .teal,
                 value: String(format: "%.1f U", snapshot.maxBolusUnits), label: "Max bolus")
        case "cob":
            pill(icon: "leaf.fill", tint: .green,
                 value: snapshot.cobGrams > 0 ? "\(Int(snapshot.cobGrams)) g" : "—", label: "Active carbs")
        default:
            EmptyView()
        }
    }

    /// Control-IQ user mode: 0 = normal, 1 = sleep, 2 = exercise.
    private var controlIQValue: String {
        guard snapshot.controlIQEnabled else { return "Off" }
        switch snapshot.controlIQMode {
        case 1: return "Sleep"
        case 2: return "Exercise"
        default: return "On"
        }
    }
    private var controlIQIcon: String {
        switch snapshot.controlIQMode {
        case 1: return "moon.zzz.fill"
        case 2: return "figure.run"
        default: return "checkmark.circle.fill"
        }
    }

    private func cgmPill(now: Date) -> some View {
        let active = snapshot.cgmActive
        // No reading → treat as hidden; otherwise fresh/stale/hidden by age.
        let present: GlucosePresentation = snapshot.glucose == nil
            ? .hidden : GlucoseFreshness.presentation(of: snapshot.glucoseDate, now: now)
        let age = snapshot.glucoseDate.map { GlucoseFreshness.ageLabel(for: $0, now: now) }
        let value: String
        let tint: Color
        switch present {
        case .hidden: value = active ? "OK" : "—"; tint = active ? AppTheme.inRange : .gray
        case .stale:  value = age ?? "—"; tint = AppTheme.low
        case .fresh:  value = age ?? "OK"; tint = AppTheme.inRange
        }
        return pill(icon: active ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward",
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
