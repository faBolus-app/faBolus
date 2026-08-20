import SwiftUI
import Charts
import faBolusCore
import faBolusDesign

/// Glucose color for the Mac app views: grey when stale or missing, else the `faBolusDesign.AppTheme`
/// band color (classified via `faBolusCore.GlucoseRange.classify`, NOT the shared
/// `RemoteClientModel.band` indirection — Phase 09.1 D-03). Replaces the deleted `MacTheme.glucoseColor`,
/// preserving its exact grey-when-stale / grey-when-nil fallback order.
private func macGlucoseColor(_ mgdl: Int?, stale: Bool) -> Color {
    if stale { return .secondary }
    guard let g = mgdl else { return .gray }
    return AppTheme.glucoseColor(g)
}

// MARK: - Status (glucose + trend + pills)

/// Big current glucose + trend arrow, grayed/aged when stale, plus a connection note.
struct MacStatusView: View {
    var model: MacRemoteModel
    // N12 (Dynamic Type): the big glucose number scales instead of a fixed 44 pt.
    @ScaledMetric(relativeTo: .largeTitle) private var glucoseFontSize: CGFloat = 44

    /// Phase 09.1 (D-04) / Phase 09.29 (D-03) — the classified band, kept ONLY for the VoiceOver word
    /// (`statusA11yLabel` below); the visual glyph this used to feed was removed in 09.29. `nil` while
    /// hidden/stale/missing (the number is already greyed/hidden then; no band color to duplicate,
    /// mirroring `StatusRingView`/`WatchHUDView`).
    private var band: GlucoseRange? {
        guard !model.glucoseHidden, !model.isGlucoseStale, let g = model.glucose else { return nil }
        return GlucoseRange.classify(g)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Past the phone's "hide after" age, hide the value ("—") like the phone/watch,
                // rather than showing a stale number. Between stale and hide it shows greyed.
                Text(model.glucoseHidden ? "—" : model.displayGlucose)
                    .font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(macGlucoseColor(model.glucose, stale: model.isGlucoseStale))
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
        // N12: read the status block as one element — "Glucose 124, ↑, 2 min ago, Connected", with
        // "stale" injected when the value is de-emphasized (grey is otherwise the only stale cue).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusA11yLabel)
    }

    /// N12: spoken description of the Mac status block, including "stale" when de-emphasized.
    /// Phase 09.1 (D-04) / Phase 09.29 (D-03): also speaks the band word for a fresh reading (mirrors
    /// `StatusRingView.a11yLabel` / `WatchHUDView.glanceGlucoseLabel`) — the visual band glyph was
    /// removed in 09.29, but the VoiceOver band word is preserved here.
    private var statusA11yLabel: String {
        var parts: [String] = []
        if model.glucoseHidden { parts.append("Glucose unavailable") }
        else {
            parts.append("Glucose \(model.displayGlucose)")
            parts.append(model.trend)
            if let band { parts.append(band.shortLabel) }
        }
        if model.isGlucoseStale { parts.append("stale") }
        if let age = model.ageLabel { parts.append(age) }
        if !model.reachable { parts.append("iPhone not reachable") }
        else if !model.connection.isEmpty { parts.append(model.connection) }
        return parts.joined(separator: ", ")
    }
}

/// Compact status pills — IOB, reservoir, battery, last bolus.
struct MacStatusPills: View {
    var model: MacRemoteModel

    var body: some View {
        let d = model.display
        HStack(spacing: 8) {
            // DIF-ux: grey + age the IOB pill when the host couldn't confirm the active-insulin read fresh.
            if d.showIOB { pill("IOB", String(format: "%.2f U", model.iobUnits), stale: model.isIobStale, age: model.iobAgeLabel) }
            if d.showReservoir { pill("Reservoir", String(format: "%.0f U", model.reservoirUnits)) }
            if d.showBattery { pill("Battery", "\(model.batteryPercent)%") }
            if d.showLastBolus, let last = model.lastBolusUnits {
                pill("Last", String(format: "%.2f U", last))
            }
            // Phase 09.15 T1-1 (D-01/D-08): full Tandem zone word (Mac has room) — 5th pill. ABSENT
            // (never a stale last-known word) unless Control-IQ is running and the token maps to a
            // member of the fixed five (D-06 guardrails #5/#6, SP-5 fail-closed).
            if let zone = ciqZone { pill("Control-IQ", zone.rawValue.capitalized) }
            // Phase 09.15 T1-2 (D-09.1 BINDING fail-closed cause-attribution) — a conditional pill
            // shown ONLY while the pump's OWN control-state has confirmed the ACTIVE suspend is
            // Control-IQ's. Mac has no generic-suspend wire signal to fall back to (unlike the iPhone's
            // pre-existing bare "Suspended" pill), so absent/false renders nothing extra — byte-identical
            // to Mac's pre-T1-2 behavior, which never showed a suspend pill either.
            if let elapsed = ciqSuspendedForLowElapsed { pill("Basal", "Control-IQ paused · \(elapsed)") }
        }
    }

    /// `nil` whenever Control-IQ isn't running or the token is absent/unmapped.
    private var ciqZone: ControlIQZone? {
        guard model.controlIQEnabled, let raw = model.ciqZone else { return nil }
        return ControlIQZone(rawValue: raw)
    }

    /// `nil` unless the pump's OWN control-state has confirmed the suspend is Control-IQ's (D-09.1
    /// BINDING) — never inferred from a generic suspend signal Mac doesn't have.
    private var ciqSuspendedForLowElapsed: String? {
        guard model.ciqSuspendedForLow == true, let start = model.ciqSuspendStartDate else { return nil }
        return ControlIQSuspendAttribution.elapsedMinutesLabel(since: start)
    }

    private func pill(_ title: String, _ value: String, stale: Bool = false, age: String? = nil) -> some View {
        // DIF-ux: a stale calc-input pill names its age and tints orange (mirrors the phone's CGM/IOB).
        let shownTitle = (stale && age != nil) ? "\(title) · \(age!)" : title
        return VStack(spacing: 2) {
            Text(shownTitle).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).fontWeight(.medium)
                .foregroundStyle(stale ? .orange : .primary)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        // N12: one element reading "<title>, <value>" (+ "stale" when greyed — the orange tint is
        // otherwise the only stale cue).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "\(shownTitle), \(value), stale" : "\(shownTitle), \(value)")
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
                        .foregroundStyle(AppTheme.inRange.opacity(0.12))
                    ForEach(pts.indices, id: \.self) { i in
                        // D-08: symmetric clamp using the PHONE-scoped shared bounds (D-07) — the
                        // point's color still classifies off the TRUE unclamped reading.
                        let plottedY = GlucosePlotScale.clamp(pts[i].mgdl, floor: model.glucosePlotFloor,
                                                              ceiling: model.glucosePlotCeiling)
                        PointMark(x: .value("t", pts[i].date), y: .value("mg/dL", plottedY))
                            .foregroundStyle(AppTheme.glucoseColor(pts[i].mgdl)).symbolSize(8)
                    }
                }
                // D-07 CRITICAL: the Mac is in the PHONE group — it reads the shared
                // glucosePlotFloor/Ceiling getters directly, NEVER smallScreenFloor/Ceiling and NEVER
                // anything derived from model.chartRanges (that channel is the tap-through time-range
                // mirror, a different concept — do not repeat the watchChartRanges conflation here).
                .chartYScale(domain: model.glucosePlotFloor...model.glucosePlotCeiling)
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

    /// A relayed pump/calc row. `stale`/`age` are set (DIF-ux) for the calc-input rows the host couldn't
    /// confirm fresh, so they grey + name their age like the phone's status pills; other rows leave them off.
    private struct Row: Identifiable {
        let title: String, value: String
        var stale = false
        var age: String? = nil
        var id: String { title }
    }

    private var rows: [Row] {
        let iobStale = model.isIobStale, therapyStale = model.isTherapyStale
        var out: [Row] = [
            Row(title: "Active insulin", value: String(format: "%.2f U", model.iobUnits),
                stale: iobStale, age: model.iobAgeLabel),
            Row(title: "Reservoir", value: "\(Int(model.reservoirUnits)) U"),
            Row(title: "Pump battery", value: model.batteryPercent > 0 ? "\(model.batteryPercent)%" : "—"),
            Row(title: "Basal", value: String(format: "%.2f U/hr", model.basalRate)),
            Row(title: "CGM", value: model.cgmActive ? "Active" : "Inactive"),
        ]
        if let last = model.lastBolusUnits { out.append(Row(title: "Last bolus", value: String(format: "%.2f U", last))) }
        out.append(Row(title: "Carb ratio", value: model.carbRatio > 0 ? String(format: "%.0f g/U", model.carbRatio) : "—",
                       stale: therapyStale, age: model.therapyAgeLabel))
        out.append(Row(title: "Correction (ISF)", value: model.isf > 0 ? "\(model.isf)" : "—",
                       stale: therapyStale, age: model.therapyAgeLabel))
        out.append(Row(title: "Target", value: model.targetBg > 0 ? "\(model.targetBg)" : "—",
                       stale: therapyStale, age: model.therapyAgeLabel))
        out.append(Row(title: "Max bolus", value: String(format: "%.1f U", model.maxBolusUnits)))
        // Phase 09.15 T1-3 (D-01/D-08, SP-5 fail-closed): Mac has room for the full row (unlike the
        // iPhone pill's compact form); appended only when an auto-correction has actually been seen —
        // never a stale/fabricated age.
        if let age = model.lastAutoCorrectionAgeLabel {
            out.append(Row(title: "Auto-correction", value: age))
        }
        // Phase 09.15 T1-4 (D-01/D-08) — a single conditional marker row (NOT a remote-side timeline;
        // Mac never had the pump history). Appended only when the marker is present.
        if let age = model.ciqLastCouldNotDeliverAgeLabel {
            out.append(Row(title: "Control-IQ", value: "Couldn't deliver (\(age))"))
        }
        if !model.connection.isEmpty { out.append(Row(title: "Pump", value: model.connection)) }
        return out
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows) { r in
                HStack {
                    // DIF-ux: a stale calc-input row names its age and tints orange (like the phone).
                    Text((r.stale && r.age != nil) ? "\(r.title) · \(r.age!)" : r.title)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(r.value).font(.caption.monospacedDigit()).fontWeight(.medium)
                        .foregroundStyle(r.stale ? .orange : .primary)
                }
                // N12: each detail row reads as one element — "Active insulin, 1.23 U" (+ "stale").
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(macRowLabel(r))
            }
        }
        // Phase 09.15 T1-9 (D-01, D-08): full Sleep/Exercise facts + window text (Mac has room) — a
        // separate conditional card below the Row table. No Smart-Assist gate here — matches every
        // other 09.15 Mac readout (ciqZone/ciqSuspend/lastAutoCorrection): the per-feature toggle is
        // phone-local and not yet mirrored to remotes on the wire (a known, accepted cross-plan gap,
        // not introduced by this plan). Fail-closed: absent unless a preset is actively selected by
        // the mirrored `controlIQMode` (never a "Normal mode" card).
        if let preset = model.ciqActivityPreset {
            MacSleepExerciseCard(model: model, preset: preset)
        }
    }

    /// N12: spoken description of a details row, with age + "stale" when the calc input is de-emphasized.
    private func macRowLabel(_ r: Row) -> String {
        let title = (r.stale && r.age != nil) ? "\(r.title) · \(r.age!)" : r.title
        return r.stale ? "\(title), \(r.value), stale" : "\(title), \(r.value)"
    }
}

/// Phase 09.15 T1-9 (D-01, D-06 guardrail #4, D-08) — the full Sleep/Exercise facts + window text
/// card (Mac has room, unlike the compact Watch/Garmin form). Mutual-exclusivity is structural:
/// `MacDetailsView.body` only constructs this view when `model.ciqActivityPreset` selected exactly
/// one preset, and `isSleep` picks exactly one branch below — Sleep and Exercise facts can never
/// render together. Each fact line renders independently (partial-state coverage, D-08).
private struct MacSleepExerciseCard: View {
    var model: MacRemoteModel
    let preset: ActivityPreset
    private var isSleep: Bool { preset.name == "Sleep" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isSleep ? "moon.zzz.fill" : "figure.run")
                    .foregroundStyle(AppTheme.insulin)
                    .accessibilityHidden(true)
                Text("\(preset.name) Activity is on").font(.callout.weight(.semibold))
            }
            Text(SleepExerciseAwareness.targetAutoBolusLine(preset)).font(.caption).foregroundStyle(.secondary)
            if let threshold = SleepExerciseAwareness.suspendThresholdLine(preset) {
                Text(threshold).font(.caption).foregroundStyle(.secondary)
            }
            if isSleep {
                if let window = model.ciqSleepWindowLine {
                    Text(window).font(.caption).foregroundStyle(.secondary)
                }
            } else if let remaining = SleepExerciseAwareness.remainingLabel(seconds: model.exerciseTimeRemainingSec) {
                Text(remaining).font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
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
        case .pumpNotLinked, .bolusInFlight, .remoteUnreachable, .accessDenied, .noCartridge:
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
                // T1-5 (D-01, D-06 "never adjacent to a dose CTA", D-08): the countdown bar renders
                // FIRST in this disclosure block, ABOVE the amount entry — same placement rule as
                // `BolusEntryView` (more separated from the Deliver button below than the existing
                // ambient/lockout lines further down). Fail-closed: nil fraction ⇒ no bar at all. No
                // Smart-Assist gate here — matches every other 09.15 Mac readout (ciqZone/ciqSuspend/
                // lastAutoCorrection): the per-feature toggle is phone-local and not yet mirrored to
                // remotes on the wire (a known, accepted cross-plan gap, not introduced by this plan).
                if let fraction = model.lockoutRemainingFraction, let availableAt = model.lockoutAvailableAt {
                    MacLockoutCountdownBarView(fraction: fraction, availableAt: availableAt)
                }
                Picker("", selection: $mode) {
                    Text("Carbs").tag("carbs")
                    Text("Units").tag("units")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, _ in amount = nil }
                .accessibilityLabel("Bolus mode")

                // Type a value directly, or use the − / + stepper. Both edit the same amount.
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    TextField("Amount", value: $amount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84)
                        .onSubmit { if let a = amount { amount = min(max(0, a), maxV) } }
                        .accessibilityLabel(isCarbs ? "Amount, grams" : "Amount, units")
                    Text(unitLabel).foregroundStyle(.secondary)
                    Stepper("", value: stepperBinding, in: 0...maxV, step: step)
                        .labelsHidden()
                        .accessibilityLabel(isCarbs ? "Carbs" : "Bolus units")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                // In carbs mode, preview the units the phone will deliver (like the Garmin).
                if let u = estUnits {
                    Text(String(format: "≈ %.2f U", u))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // B2 (S1+O3): the controller auto-correction disclosure — reconstructed locally from the
                // mirrored controllerVariant + controlIQEnabled, matching the phone bolus screen. Facts
                // only; NEVER gates/changes/delays the dose.
                if let ambient = model.autoCorrectionAmbient {
                    Label(ambient, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                }
                if let lockout = model.autoCorrectionLockout {
                    Label(lockout, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                }

                Button {
                    if let a = amount { amount = min(max(0, a), maxV) }   // clamp typed value
                    if canDeliver { confirming = true }
                } label: {
                    Text(bolusButtonLabel).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDeliver)
                .accessibilityLabel(bolusButtonLabel)
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

// MARK: - T1-5 lockout countdown bar

/// T1-5 — the 60-min auto-correction lockout COUNTDOWN bar, full Mac-width: a linear TIME-FILL capsule
/// (fraction = elapsed/window, filling UP toward 1.0 as availability returns — NEVER a draining
/// battery). Flat `AppTheme.insulin` fill on a `.quaternary` track, single tone regardless of fraction —
/// never red/amber near completion (D-06 explicit gauge-neutrality rule). Copy verbatim from the
/// UI-SPEC Copywriting Contract. A separate struct from `BolusEntryView`'s `LockoutCountdownBarView`
/// (a distinct app target — Mac can't import an iOS-app-target type), same visual contract.
struct MacLockoutCountdownBarView: View {
    let fraction: Double
    let availableAt: Date

    private var justFired: Bool { fraction < 0.02 }
    private var timeLabel: String { availableAt.formatted(date: .omitted, time: .shortened) }
    private var clampedFraction: Double { min(max(fraction, 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if justFired {
                Text("Just paused — next correction available at \(timeLabel)")
                    .font(.caption)
            } else {
                HStack {
                    Text("Control-IQ's next automatic correction").font(.caption)
                    Spacer()
                    Text("available at \(timeLabel)").font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(AppTheme.insulin)
                        .frame(width: geo.size.width * CGFloat(clampedFraction))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }
}
