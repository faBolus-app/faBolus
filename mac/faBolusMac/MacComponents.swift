import SwiftUI
import Charts
import faBolusCore

// MARK: - Status (glucose + trend + pills)

/// Big current glucose + trend arrow, grayed/aged when stale, plus a connection note.
struct MacStatusView: View {
    var model: MacRemoteModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Past the phone's "hide after" age, hide the value ("—") like the phone/watch,
                // rather than showing a stale number. Between stale and hide it shows greyed.
                Text(model.glucoseHidden ? "—" : model.displayGlucose)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(model.isGlucoseStale ? Color.secondary : MacTheme.glucoseColor(model.glucose))
                if !model.glucoseHidden {
                    Text(model.trend).font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            if let age = model.ageLabel {
                Text(age).font(.caption).foregroundStyle(.secondary)
            }
            if !model.reachable {
                Label("iPhone not reachable", systemImage: "wifi.slash")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !model.connection.isEmpty {
                Text(model.connection).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact status pills — IOB, reservoir, battery, last bolus.
struct MacStatusPills: View {
    var model: MacRemoteModel

    var body: some View {
        let d = model.display
        HStack(spacing: 8) {
            if d.showIOB { pill("IOB", String(format: "%.2f U", model.iobUnits)) }
            if d.showReservoir { pill("Reservoir", String(format: "%.0f U", model.reservoirUnits)) }
            if d.showBattery { pill("Battery", "\(model.batteryPercent)%") }
            if d.showLastBolus, let last = model.lastBolusUnits {
                pill("Last", String(format: "%.2f U", last))
            }
        }
    }

    private func pill(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).fontWeight(.medium)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Glucose chart (mirrors the watch chart)

/// Recent glucose history: in-range band (70–180), points colored by band, Y 40–300. Click to cycle
/// through the phone's chart ranges (default 3/6/12/24 h). Uses the host's real per-point timestamps
/// when available, else estimates 5-min spacing.
struct MacChartView: View {
    var model: MacRemoteModel
    @State private var rangeIndex = 0

    private var ranges: [Int] { model.chartRanges.isEmpty ? [6] : model.chartRanges }
    private var windowHours: Int { ranges[min(rangeIndex, ranges.count - 1)] }

    private var points: [(date: Date, mgdl: Int)] {
        let n = model.history.count
        let count = min(n, windowHours * 12)
        guard count > 0 else { return [] }
        let hist = Array(model.history.suffix(count))
        if model.historyDates.count == n {
            return Array(zip(model.historyDates.suffix(count), hist)).map { ($0, $1) }
        }
        let now = model.glucoseDate ?? Date()
        return hist.enumerated().map { i, m in (now.addingTimeInterval(Double(i - (hist.count - 1)) * 300), m) }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("History").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(windowHours)h").font(.caption2).foregroundStyle(.secondary)
            }
            let pts = points
            if pts.isEmpty {
                Text("No history yet").font(.caption).foregroundStyle(.secondary).frame(height: 90)
            } else {
                Chart {
                    RectangleMark(yStart: .value("lo", GlucoseThresholds.low), yEnd: .value("hi", GlucoseThresholds.high))
                        .foregroundStyle(.green.opacity(0.12))
                    ForEach(pts.indices, id: \.self) { i in
                        PointMark(x: .value("t", pts[i].date), y: .value("mg/dL", pts[i].mgdl))
                            .foregroundStyle(MacTheme.glucoseColor(pts[i].mgdl)).symbolSize(8)
                    }
                }
                .chartYScale(domain: 40...300)
                .chartYAxis { AxisMarks(values: [GlucoseThresholds.low, GlucoseThresholds.high, GlucoseThresholds.veryHigh]) }
                .chartXAxis(.hidden)
                .frame(height: 90)
                .contentShape(Rectangle())
                .onTapGesture { rangeIndex = (rangeIndex + 1) % ranges.count }   // click to change range
            }
        }
    }
}

// MARK: - Details (all pump data, mirrors the watch Details page)

/// Every relayed pump/calc field, matching the watch Details page (plus basal). Value-only mirror.
struct MacDetailsView: View {
    var model: MacRemoteModel

    private var rows: [(String, String)] {
        var out: [(String, String)] = [
            ("Active insulin", String(format: "%.2f U", model.iobUnits)),
            ("Reservoir", "\(Int(model.reservoirUnits)) U"),
            ("Pump battery", model.batteryPercent > 0 ? "\(model.batteryPercent)%" : "—"),
            ("Basal", String(format: "%.2f U/hr", model.basalRate)),
            ("CGM", model.cgmActive ? "Active" : "Inactive"),
        ]
        if let last = model.lastBolusUnits { out.append(("Last bolus", String(format: "%.2f U", last))) }
        out.append(("Carb ratio", model.carbRatio > 0 ? String(format: "%.0f g/U", model.carbRatio) : "—"))
        out.append(("Correction (ISF)", model.isf > 0 ? "\(model.isf)" : "—"))
        out.append(("Target", model.targetBg > 0 ? "\(model.targetBg)" : "—"))
        out.append(("Max bolus", String(format: "%.1f U", model.maxBolusUnits)))
        if !model.connection.isEmpty { out.append(("Pump", model.connection)) }
        return out
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(r.1).font(.caption.monospacedDigit()).fontWeight(.medium)
                }
            }
        }
    }
}

// MARK: - Bolus entry

/// Units/carbs entry that relays a bolus to the phone (which converts carbs→units and executes it).
/// Requires a confirmation before sending — never a one-click dispense. While a bolus is in flight
/// it shows progress + a Cancel button.
struct MacBolusEntryView: View {
    var model: MacRemoteModel
    @State private var mode: String = "carbs"
    // Optional so the field starts empty (no stale value, no "0" to clear before typing).
    @State private var amount: Double? = nil
    @State private var confirming = false

    private var isDelivering: Bool { model.lastStatus == .delivering }
    /// A rejected/failed bolus (e.g. the host's divergence guard) — shown in the entry form so the
    /// reason is visible in the popover (the delivering view only shows while actively delivering).
    private var showFailure: Bool {
        (model.lastStatus == .failed || model.lastStatus == .outOfRange) && (model.statusMessage?.isEmpty == false)
    }
    private var isCarbs: Bool { mode == "carbs" }
    private var step: Double { isCarbs ? model.display.carbIncrement : model.display.bolusIncrement }
    private var maxV: Double { isCarbs ? 200 : (model.maxBolusUnits > 0 ? model.maxBolusUnits : 25) }
    private var unitLabel: String { isCarbs ? "g" : "U" }
    private var value: Double { amount ?? 0 }
    /// Whether a bolus may be started right now, via the shared `BolusGate` so the Mac agrees with every
    /// other surface (v3 defect group D) instead of hand-rolling the check. Fed from the relayed pump
    /// state: link health (`pumpConnected`), whether a dose is already in flight (`bolusInFlight`), and
    /// the phone-pushed read-only flag — none of which the Mac honored before (it checked only
    /// reachability + bounds, so under read-only or a dropped pump link it showed a live, tappable Bolus
    /// button that the host then rejected). The bounds run in the entered unit (carb grams or insulin
    /// units) exactly as before, so a fresh field still just disables quietly.
    private var gate: (canBolus: Bool, reason: BolusBlockReason?) {
        let access: AccessPolicy.AccessDecision = model.readOnly ? .deny(.remotesReadOnly) : .allow
        return BolusGate.evaluate(
            reachable: model.reachable,
            linked: model.pumpConnected,
            bolusInFlight: model.bolusInFlight || isDelivering,
            amount: value, minimum: isCarbs ? 1 : 0.05, maximum: maxV,
            access: access)
    }
    private var canDeliver: Bool { gate.canBolus }
    /// The gate reason worth showing above the entry form — the "you can't bolus right now" states.
    /// Bounds reasons (below-min/above-max) are just "keep typing" and would nag an empty field, so they
    /// stay silent (the button simply stays disabled). Exhaustive so a new reason can't be dropped.
    private var blockMessage: String? {
        switch gate.reason {
        case .pumpNotLinked, .bolusInFlight, .remoteUnreachable, .accessDenied:
            return gate.reason?.userMessage
        case .belowMinimum, .aboveMax, .none:
            return nil
        }
    }
    /// Non-optional binding for the Stepper (treats an empty field as 0).
    private var stepperBinding: Binding<Double> {
        Binding(get: { amount ?? 0 }, set: { amount = $0 })
    }
    private var amountText: String { String(format: isCarbs ? "%.0f %@" : "%.2f %@", value, unitLabel) }
    /// In carbs mode, the units the phone would deliver (nil if unknown or nothing entered).
    private var estUnits: Double? { (isCarbs && amount != nil) ? model.estimatedUnits(forCarbs: value) : nil }
    /// Deliver-button label. Units mode shows units; carbs mode shows the estimated units by default,
    /// or the carb grams when the user prefers that (Settings → Bolus entry).
    private var bolusButtonLabel: String {
        guard amount != nil else { return "Bolus" }
        if isCarbs {
            if model.display.carbButtonInUnits, let u = estUnits { return String(format: "Bolus %.2f U", u) }
            return "Bolus \(Int(value)) g"
        }
        return String(format: "Bolus %.2f U", value)
    }

    var body: some View {
        VStack(spacing: 10) {
            if isDelivering {
                deliveringView
            } else if confirming {
                // Inline confirm — a system confirmationDialog dismisses the menu-bar popover, so the
                // second tap ("Deliver") never registers. Confirm in place instead.
                // P15 Addendum B (AB5): a carb bolus while the CGM reading is stale gets the three-way
                // choice (include the stale reading / carbs only / cancel) instead of the plain confirm.
                if isCarbs && value > 0 && model.staleCarbWarnNeeded {
                    staleConfirmView
                } else {
                    confirmView
                }
            } else {
                if showFailure, let m = model.statusMessage {
                    Text(m).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                } else if let m = blockMessage {
                    // Why the Bolus button is disabled (pump not linked / a dose in flight / read-only /
                    // phone unreachable), so the Mac explains itself instead of just greying out.
                    Text(m).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                }
                Picker("", selection: $mode) {
                    Text("Carbs").tag("carbs")
                    Text("Units").tag("units")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, _ in amount = nil }

                // Type a value directly, or use the − / + stepper. Both edit the same amount.
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    TextField("Amount", value: $amount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84)
                        .onSubmit { if let a = amount { amount = min(max(0, a), maxV) } }
                    Text(unitLabel).foregroundStyle(.secondary)
                    Stepper("", value: stepperBinding, in: 0...maxV, step: step)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                // In carbs mode, preview the units the phone will deliver (like the Garmin).
                if let u = estUnits {
                    Text(String(format: "≈ %.2f U", u))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    if let a = amount { amount = min(max(0, a), maxV) }   // clamp typed value
                    if canDeliver { confirming = true }
                } label: {
                    Text(bolusButtonLabel).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDeliver)
            }
        }
        .onAppear { mode = model.display.defaultBolusMode }
    }

    private var confirmView: some View {
        VStack(spacing: 8) {
            Text(isCarbs ? "Deliver \(Int(value)) g?" : "Deliver \(amountText)?")
                .font(.callout.weight(.semibold))
            if let u = estUnits {
                Text(String(format: "≈ %.2f U", u))
                    .font(.callout.monospacedDigit()).foregroundStyle(.primary)
            }
            Text(isCarbs ? "The iPhone calculates the dose and delivers it on the pump."
                         : "The iPhone delivers this on the pump.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            HStack {
                Button("Back") { confirming = false }
                    .buttonStyle(.bordered)
                Button("Deliver") {
                    if isCarbs { model.deliverCarbs(value) } else { model.deliverUnits(value) }
                    amount = nil
                    confirming = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// P15 Addendum B (AB5): the stale-CGM three-way, inline (a system dialog dismisses the popover).
    /// Include the stale reading (insulin-INCREASING, per-attempt), bolus for carbs only (drop the
    /// correction — today's behavior), or cancel (send NOTHING). Reached only for a carb bolus that is
    /// stale at confirm; a fresh reading routes to the plain `confirmView`. Reuses the shared
    /// `RemoteClientModel` include-stale path (AB3) so the Mac agrees with the iPhone/Watch.
    private var staleConfirmView: some View {
        VStack(spacing: 8) {
            Text("CGM reading is stale").font(.callout.weight(.semibold))
            Text(staleMessage)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
            VStack(spacing: 6) {
                if let g = model.glucose {
                    Button(includeStaleLabel(g)) {
                        model.deliverCarbs(value, includeStaleBG: true)
                        amount = nil; confirming = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(carbsOnlyLabel) {
                    model.deliverCarbs(value)
                    amount = nil; confirming = false
                }
                .buttonStyle(.bordered)
                Button("Cancel") { confirming = false }   // sends NOTHING
                    .buttonStyle(.bordered)
            }
        }
    }

    /// The include-stale button label: the stale value and the dose it WOULD produce (correction added).
    private func includeStaleLabel(_ g: Int) -> String {
        if let u = model.estimatedUnits(forCarbs: value, includeStaleBG: true) {
            return "Include \(g) mg/dL → " + String(format: "%.2f U", u)
        }
        return "Include \(g) mg/dL"
    }
    /// The carbs-only button label: the correction dropped (today's silent behavior, now acknowledged).
    private var carbsOnlyLabel: String {
        if let u = model.estimatedUnits(forCarbs: value) {
            return "Carbs only → " + String(format: "%.2f U", u)
        }
        return "Carbs only"
    }
    /// Shared warning lead (identical wording across surfaces) when the age is known; a compact fallback
    /// when the reading has no source timestamp (still stale, but no age to name).
    private var staleMessage: String {
        if let g = model.glucose, let d = model.glucoseDate {
            return StaleBolusPrompt.warningMessage(glucoseMgdl: g, glucoseDate: d)
        }
        return "Your CGM reading is stale and was left out of this dose. Include it, bolus for carbs only, or cancel."
    }

    private var deliveringView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.statusMessage ?? "Delivering…").font(.callout)
            }
            Button("Cancel bolus", role: .destructive) { model.cancel() }
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - Alerts

/// Active pump alerts with a dismiss action (relayed to the phone).
struct MacAlertsView: View {
    var model: MacRemoteModel

    var body: some View {
        if model.alerts.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.alerts.enumerated()), id: \.offset) { _, alert in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(alert.title).font(.callout)
                        Spacer()
                        Button(model.canDismissAlertOnPump ? "Clear" : "Snooze") { model.dismissAlert(alert) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }
}
