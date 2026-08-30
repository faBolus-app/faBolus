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
            // Grey + age when IOB is stale (`CalcInputFreshness`). Missing date ⇒ no age, never
            // invented as fresh on the dose path.
            let iobStale = CalcInputFreshness.iobPresentation(of: snapshot.iobDate, now: now) == .stale
            // `…IfRead` funnel: a pump that has never answered op-109 has NO active-insulin value, and
            // `iobUnits` is a non-optional `0`, so this used to render a confident `0.00 U` — with the
            // FRESH insulin tint, because `iobPresentation(of: nil)` is `.hidden`, not `.stale`, so the
            // `== .stale` test above read the absent case as fresh. A real 0.00 U IOB (very common) still
            // renders `0.00 U`; only "never reported" renders "—". Sibling of the reservoir/battery fix
            // from debug `tslim-reservoir-battery-zero`.
            let iob = PumpValuePresentation.make(snapshot.iobUnitsIfRead, format: "%.2f U")
            pill(
                icon: "drop.fill",
                // Unknown is neither live nor a warning: grey, exactly like the unknown reservoir below.
                tint: !iob.isKnown ? .gray : (iobStale ? AppTheme.low : AppTheme.insulin),
                value: iob.valueText,
                label: calcAgedLabel("Active Insulin", date: snapshot.iobDate, stale: iobStale, now: now),
                stale: iobStale)
        case "reservoir":
            // Through `ReservoirPresentation` so an UNREAD reservoir shows "—", never a fabricated
            // "0 U" (debug `tslim-reservoir-battery-zero`). Greyed while unknown, like the stale-IOB
            // treatment above — an absent reading is not live data.
            let reservoir = ReservoirPresentation.make(units: snapshot.reservoirUnitsIfRead)
            pill(
                icon: "cross.vial.fill", tint: reservoir.isKnown ? .teal : .gray,
                value: reservoir.valueText, label: "Reservoir")
        case "battery":
            // Single glyph/"Charging"/tint decision — don't fork a second level→glyph switch.
            // `…IfRead` (not the raw percent) so an unread battery can't render as a dead one.
            let battery = BatteryChargingPresentation.make(
                percent: snapshot.batteryPercentIfRead,
                charging: snapshot.batteryCharging)
            pill(
                icon: battery.symbolName,
                tint: battery.usesLowTint ? AppTheme.low : .green,
                value: battery.valueText,
                label: "Pump")
        case "cgm":
            cgmPill(now: now)
        case "basal":
            if snapshot.deliverySuspended {
                pill(icon: "pause.circle.fill", tint: AppTheme.low, value: "Suspended", label: "Delivery")
            } else {
                // `…IfRead` funnel on `basalRateKnown`. Before this, a pump that had never answered
                // op-41 rendered a confident `0.00 U/hr` — which reads as "delivery stopped", the one
                // claim this pill must not fabricate, and the exact reason `basalRateKnown` was added
                // (it had NO consumer until now). A real 0.00 U/hr — a 0 U/hr temp rate, or a suspend
                // that the `deliverySuspended` branch above hasn't caught — still shows `0.00 U/hr`.
                let basal = PumpValuePresentation.make(snapshot.basalRateUnitsPerHourIfRead, format: "%.2f U/hr")
                pill(
                    icon: "waveform.path.ecg", tint: basal.isKnown ? AppTheme.insulin : .gray,
                    value: basal.valueText, label: "Basal")
            }
        case "controlIQ":
            pill(
                icon: controlIQIcon, tint: snapshot.controlIQEnabled ? AppTheme.inRange : .gray,
                value: controlIQValue, label: "Control-IQ")
        case "lastBolus":
            pill(
                icon: "drop.triangle.fill", tint: AppTheme.insulin,
                value: snapshot.lastBolusUnits.map { String(format: "%.2f U", $0) } ?? "—", label: "Last bolus")
        case "carbRatio":
            let thStale = therapyStale(now)
            pill(
                icon: "fork.knife", tint: thStale ? AppTheme.low : .orange,
                value: snapshot.carbRatio > 0 ? String(format: "%.0f g/U", snapshot.carbRatio) : "—",
                label: calcAgedLabel("Carb ratio", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                stale: thStale)
        case "isf":
            let thStale = therapyStale(now)
            pill(
                icon: "arrow.down.right.circle", tint: thStale ? AppTheme.low : .purple,
                value: snapshot.isf > 0 ? "\(snapshot.isf)" : "—",
                label: calcAgedLabel("ISF", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                stale: thStale)
        case "target":
            let thStale = therapyStale(now)
            pill(
                icon: "target", tint: thStale ? AppTheme.low : AppTheme.inRange,
                value: snapshot.targetBg > 0 ? "\(snapshot.targetBg)" : "—",
                label: calcAgedLabel("Target", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                stale: thStale)
        case "maxBolus":
            pill(
                icon: "gauge.with.dots.needle.67percent", tint: .teal,
                value: String(format: "%.1f U", snapshot.maxBolusUnits), label: "Max bolus")
        case "cob":
            pill(
                icon: "leaf.fill", tint: .green,
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
        // No reading → hidden; otherwise fresh/stale/hidden by age.
        let present: GlucosePresentation =
            snapshot.glucose == nil
            ? .hidden : GlucoseFreshness.presentation(of: snapshot.glucoseDate, now: now)
        let age = snapshot.glucoseDate.map { GlucoseFreshness.ageLabel(for: $0, now: now) }
        let value: String
        let tint: Color
        switch present {
        case .hidden:
            value = active ? "OK" : "—"
            tint = active ? AppTheme.inRange : .gray
        case .stale:
            value = age ?? "—"
            tint = AppTheme.low
        case .fresh:
            value = age ?? "OK"
            tint = AppTheme.inRange
        }
        return pill(
            icon: active ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward",
            tint: tint, value: value, label: "CGM", stale: present == .stale)
    }

    /// Therapy params (CR/ISF/target share one op-115 stamp) stale for display.
    private func therapyStale(_ now: Date) -> Bool {
        CalcInputFreshness.therapyPresentation(of: snapshot.therapyParamsDate, now: now) == .stale
    }
    /// Age on a stale calc-input label so a greyed pill also names how old.
    private func calcAgedLabel(_ base: String, date: Date?, stale: Bool, now: Date) -> String {
        guard stale, let d = date else { return base }
        return "\(base) · \(CalcInputFreshness.ageLabel(for: d, now: now))"
    }

    private func pill(icon: String, tint: Color, value: String, label: String, stale: Bool = false) -> some View {
        HStack(spacing: 8) {
            // Decorative — label/value already name the field; don't announce the SF Symbol.
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
        // One VoiceOver element. Append "stale" — otherwise that state is only the grey tint.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "\(label), \(value), stale" : "\(label), \(value)")
    }
}
