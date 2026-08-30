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
            // `…IfFresh(now:)` funnel. Two defects closed here in sequence. First
            // (`tslim-reservoir-battery-zero`): `iobUnits` is a non-optional `0`, so a pump that never
            // answered op-109 rendered a confident `0.00 U` — with the FRESH insulin tint, because
            // `iobPresentation(of: nil)` is `.hidden`, not `.stale`, so the `== .stale` test above read
            // the absent case as fresh. Second (`pump-value-decay-to-unknown`): a value received once was
            // then shown as current forever. A real 0.00 U IOB — the common state between boluses — still
            // renders `0.00 U` while fresh.
            //
            // The window here is `CalcInputFreshness.staleAfterIob`, NOT the CGM window the reservoir and
            // battery pills use, so `iob.isKnown == false` and `iobStale == true` are the SAME condition
            // by construction (see `PumpSnapshot.iobUnitsIfFresh`). That is deliberate: this row and the
            // bolus calculator's own gate can never disagree. It also means the value and the age come
            // from different places on purpose — the value decays to "—" while `calcAgedLabel` keeps
            // showing "Active Insulin · 7 min ago" off `iobDate`, so the user is told WHY it is unknown
            // rather than just that it is.
            let iob = PumpValuePresentation.make(snapshot.iobUnitsIfFresh(now: now), format: "%.2f U")
            pill(
                icon: "drop.fill",
                // Unknown is neither live nor a warning: grey, exactly like the unknown reservoir below.
                // No `iobStale ? AppTheme.low` branch — it would be unreachable now that decay and
                // staleness are one predicate, and a warning tint on a value we do not have would assert
                // something we cannot know.
                tint: iob.isKnown ? AppTheme.insulin : .gray,
                value: iob.valueText,
                label: calcAgedLabel("Active Insulin", date: snapshot.iobDate, stale: iobStale, now: now),
                stale: iobStale)
        case "reservoir":
            // Through `ReservoirPresentation` so an UNREAD reservoir shows "—", never a fabricated
            // "0 U" (debug `tslim-reservoir-battery-zero`). Greyed while unknown, like the stale-IOB
            // treatment above — an absent reading is not live data.
            //
            // `…IfFresh(now:)` rather than `…IfRead`: a value the pump reported once but has not
            // re-reported inside the CGM staleness window has stopped being current, and this pill is
            // the surface that most looks like a live gauge (debug `pump-value-decay-to-unknown`). The
            // `TimelineView` above ticks every 20 s, so the decay appears without a new pump read. A
            // genuinely empty cartridge still reads "0 U" while fresh — the gate is age, not value.
            let reservoir = ReservoirPresentation.make(units: snapshot.reservoirUnitsIfFresh(now: now))
            pill(
                icon: "cross.vial.fill", tint: reservoir.isKnown ? .teal : .gray,
                value: reservoir.valueText, label: "Reservoir")
        case "battery":
            // Single glyph/"Charging"/tint decision — don't fork a second level→glyph switch.
            // `…IfFresh(now:)` (not the raw percent, and not the presence-only `…IfRead`) so neither an
            // unread NOR a gone-quiet battery can render as a dead one. A real 0 % still shows 0 %.
            let battery = BatteryChargingPresentation.make(
                percent: snapshot.batteryPercentIfFresh(now: now),
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
        // The three therapy rows all decay on `CalcInputFreshness.staleAfterTherapy` via the
        // `…IfFresh(now:)` funnels — the therapy dose gate's own window, so these rows can never claim a
        // carb ratio the calculator has already stopped trusting (`pump-value-decay-to-unknown`). One
        // op-115 frame resolves all three, so they share a stamp and decay together. As with IOB, the
        // value goes to "—" while `calcAgedLabel` keeps showing the age off `therapyParamsDate`, and the
        // tint greys rather than warning: `thStale` and `!isKnown` are one predicate here by
        // construction, so the old `AppTheme.low` branch was unreachable.
        //
        // Note these three have NO genuine-zero case, unlike reservoir/battery: a carb ratio, correction
        // factor or target of `0` is physically impossible, so `0` has always meant unread. The funnels
        // preserve that exactly.
        case "carbRatio":
            let thStale = therapyStale(now)
            let cr = snapshot.carbRatioIfFresh(now: now)
            pill(
                icon: "fork.knife", tint: cr == nil ? .gray : .orange,
                value: cr.map { String(format: "%.0f g/U", $0) } ?? PumpValuePresentation.unknownText,
                label: calcAgedLabel("Carb ratio", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                stale: thStale)
        case "isf":
            let thStale = therapyStale(now)
            let isf = snapshot.isfIfFresh(now: now)
            pill(
                icon: "arrow.down.right.circle", tint: isf == nil ? .gray : .purple,
                value: isf.map { "\($0)" } ?? PumpValuePresentation.unknownText,
                label: calcAgedLabel("ISF", date: snapshot.therapyParamsDate, stale: thStale, now: now),
                stale: thStale)
        case "target":
            let thStale = therapyStale(now)
            let target = snapshot.targetBgIfFresh(now: now)
            pill(
                icon: "target", tint: target == nil ? .gray : AppTheme.inRange,
                value: target.map { "\($0)" } ?? PumpValuePresentation.unknownText,
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
