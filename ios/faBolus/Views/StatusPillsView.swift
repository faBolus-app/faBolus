import SwiftUI
import faBolusCore
import faBolusDesign

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
            // DIF-ux: grey (AppTheme.low) + age the IOB pill when the active-insulin read is stale, via the
            // shared `CalcInputFreshness` presentation — mirrors `cgmPill`. Absent date ⇒ hidden ⇒ no age to
            // show ⇒ normal styling (like the CGM pill), never invented as fresh on the dose path itself.
            let iobStale = CalcInputFreshness.iobPresentation(of: snapshot.iobDate, now: now) == .stale
            pill(icon: "drop.fill", tint: iobStale ? AppTheme.low : AppTheme.insulin,
                 value: String(format: "%.2f U", snapshot.iobUnits),
                 label: calcAgedLabel("Active Insulin", date: snapshot.iobDate, stale: iobStale, now: now),
                 stale: iobStale)
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
        case "ciqZone":
            // Phase 09.15 T1-1 (D-01/D-08): the pill renders ABSENT (not a "no data" placeholder) unless
            // the Smart-Assist toggle is on, Control-IQ is running, AND the token maps to a member of the
            // fixed five — never a stale last-known or fabricated 6th word (D-06 guardrails #5/#6).
            if let zone = ciqZoneChip {
                pill(icon: ciqZoneIcon(zone), tint: AppTheme.insulin,
                     value: zone.rawValue.capitalized, label: "Control-IQ")
                    .accessibilityLabel("Control-IQ \(zone.rawValue.capitalized) insulin delivery")
            } else {
                EmptyView()
            }
        case "lastBolus":
            pill(icon: "drop.triangle.fill", tint: AppTheme.insulin,
                 value: snapshot.lastBolusUnits.map { String(format: "%.2f U", $0) } ?? "—", label: "Last bolus")
        case "carbRatio":
            let thStale = therapyStale(now)
            pill(icon: "fork.knife", tint: thStale ? AppTheme.low : .orange,
                 value: snapshot.carbRatio > 0 ? String(format: "%.0f g/U", snapshot.carbRatio) : "—",
                 label: calcAgedLabel("Carb ratio", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                 stale: thStale)
        case "isf":
            let thStale = therapyStale(now)
            pill(icon: "arrow.down.right.circle", tint: thStale ? AppTheme.low : .purple,
                 value: snapshot.isf > 0 ? "\(snapshot.isf)" : "—",
                 label: calcAgedLabel("ISF", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                 stale: thStale)
        case "target":
            let thStale = therapyStale(now)
            pill(icon: "target", tint: thStale ? AppTheme.low : AppTheme.inRange,
                 value: snapshot.targetBg > 0 ? "\(snapshot.targetBg)" : "—",
                 label: calcAgedLabel("Target", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                 stale: thStale)
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

    /// Phase 09.15 T1-1 (D-01/D-08, SP-5 fail-closed) — `nil` whenever the Smart-Assist toggle is off,
    /// Control-IQ isn't running, or the token is absent/unmapped; never a stale last-known zone.
    private var ciqZoneChip: ControlIQZone? {
        guard AppSettings.shared.ciqStateReadoutsEnabled, snapshot.controlIQEnabled,
              let raw = snapshot.ciqZone else { return nil }
        return ControlIQZone(rawValue: raw)
    }
    private func ciqZoneIcon(_ zone: ControlIQZone) -> String {
        switch zone {
        case .increases: return "arrow.up.circle.fill"
        case .decreases: return "arrow.down.circle.fill"
        case .maintains: return "equal.circle.fill"
        case .stops: return "pause.circle.fill"
        case .delivers: return "bolt.circle.fill"
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
                    tint: tint, value: value, label: "CGM", stale: present == .stale)
    }

    /// DIF-ux: whether the therapy params (CR/ISF/target — one shared op-115 stamp) are stale for display.
    private func therapyStale(_ now: Date) -> Bool {
        CalcInputFreshness.therapyPresentation(of: snapshot.therapyParamsDate, now: now) == .stale
    }
    /// DIF-ux: append the read's age to a calc-input pill's label when it's stale ("Active Insulin · 7 min
    /// ago"), so a greyed pill also names HOW old — mirroring the CGM pill's age readout.
    private func calcAgedLabel(_ base: String, date: Date?, stale: Bool, now: Date) -> String {
        guard stale, let d = date else { return base }
        return "\(base) · \(CalcInputFreshness.ageLabel(for: d, now: now))"
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

    private func pill(icon: String, tint: Color, value: String, label: String, stale: Bool = false) -> some View {
        HStack(spacing: 8) {
            // N12: the tint-colored SF Symbol is decorative (the label/value already name the field),
            // so it's hidden from VoiceOver to avoid reading the raw symbol name.
            Image(systemName: icon).foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        // N12: one VoiceOver element reading "<label>, <value>" (the aged label already carries the
        // "· N min ago" when stale). "stale" is appended so a greyed pill also SAYS it's stale — that
        // state is otherwise conveyed only by the grey (AppTheme.low) tint.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "\(label), \(value), stale" : "\(label), \(value)")
    }
}
