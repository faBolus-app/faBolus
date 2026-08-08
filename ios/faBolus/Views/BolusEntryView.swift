import SwiftUI
import faBolusCore

/// Bolus entry (modern). Carbs (+ optional BG) → recommended dose, or a plain Units dial —
/// default mode and the ± increments come from Settings. Experimental; enforces the
/// max-units interlock and an explicit confirm. Works as a tab (`embedded`) or a sheet.
struct BolusEntryView: View {
    let model: AppModel
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared

    @State private var mode: BolusMode = .carbs
    @State private var modeInitialized = false
    // Amounts are text-backed so an empty field shows a greyed placeholder "0" (nothing to delete
    // before typing). The numeric values are derived; the +/- steppers write formatted text back.
    @State private var carbsText = ""
    @State private var bg = ""
    @State private var unitsText = ""
    @State private var recommendation: BolusRecommendation?
    @State private var confirming = false
    @State private var delivering = false
    @State private var showReasoning = false
    // Extended (combo) bolus
    @State private var extendedOn = false
    @State private var extendedDurationMin = 120
    @State private var extendedNowPercent = 50
    @State private var confirmingExtended = false
    /// Where the correction BG came from: auto-filled from the CGM, or typed by the user. Only a
    /// CGM-sourced BG is auto-refreshed / re-checked for freshness (a typed BG is the user's own).
    private enum BGSource { case none, cgm, manual }
    @State private var bgSource: BGSource = .none
    @State private var preparingDeliver = false
    /// Wall-clock (receive) time the CGM value last changed on the phone — used to catch a reading that
    /// landed in the last ~2 s before the user tapped deliver (the on-screen dose may not reflect it yet).
    @State private var lastCGMChangeAt: Date?
    @State private var tick = Date()   // drives the live "N min ago" readout while the screen is open
    /// Set when a fresh CGM pulled at delivery time would change the dose — asks the user which to use.
    @State private var cgmUpdate: CGMUpdatePrompt?
    /// `newBG == -1` means "no fresh CGM available" — the correction is dropped (carbs-only) rather than
    /// dosed off a stale on-screen value (audit C-04 fail-closed). `extended` routes the choice back to
    /// the matching delivery path so standard + extended share one confirm flow.
    private struct CGMUpdatePrompt: Identifiable {
        let id = UUID(); let newBG: Int; let newUnits: Double; let oldUnits: Double; let extended: Bool
        // Addendum B: when the reading is stale (not merely missing), the stale value + the dose it WOULD
        // produce, so the "CGM unavailable" prompt can offer a third choice — include the stale reading.
        // nil ⇒ no reading at all (nothing to include; carbs-only / cancel only), per StaleBolusPrompt.
        var staleBG: Int? = nil
        var staleUnits: Double? = nil
    }
    /// Supersedes out-of-order async recommendation results (audit C-04).
    @State private var calcSeq = 0
    /// DIF-ux: the calc-input freshness prompt shown at deliver time when the recommendation's inputs
    /// weren't confirmed fresh this compose (`inputsVerified == false`). Carries the override dose
    /// (precomputed off last-known values, so the button label == the delivered amount) and which
    /// override(s) the "use / include" button applies. Per-attempt — reset on every recompute
    /// (`calculate()`), never sticky, never default-selected. Replaces the FB-01 single assumed-ack gate.
    private struct CalcInputPrompt: Identifiable {
        enum Kind { case iob, therapy, both }
        let id = UUID()
        let kind: Kind
        let extended: Bool
        let overrideUnits: Double          // dose recomputed with the accepted override(s) applied
        let allowStaleIob: Bool
        let allowStaleTherapy: Bool
        let iobUnits: Double
        let iobDate: Date?
        let assumedProfile: BolusMath.Profile?
        let therapyDate: Date?
    }
    @State private var calcInputPrompt: CalcInputPrompt?
    /// DIF-ux: the override the owner accepted for THIS attempt, captured when they tap the warned dialog's
    /// "use last-known" button. Re-entering `attemptDeliver` with this set SKIPS the warning gate but runs
    /// the SAME deliver-time machinery every verified dose does — the fresh-CGM refresh, the 0.10 U
    /// divergence guard, and (critically) the Addendum-B stale-CGM three-way — with these flags threaded
    /// into each recompute. So a stale-IOB/therapy override never bypasses the stale-CGM warning and never
    /// doses a correction off an unrefreshed on-screen glucose. `baseline` is the dose the button showed
    /// (off the compose-time BG), used as the divergence comparison point so the guard catches a real CGM
    /// move, not the expected correction. Consumed-and-cleared at the top of `attemptDeliver` → per-attempt,
    /// never sticky. Remotes never reach any of this (they fail closed in `resolveRemoteDose`).
    private struct AcceptedOverride { let allowStaleIob: Bool; let allowStaleTherapy: Bool; let baseline: Double }
    @State private var acceptedOverride: AcceptedOverride?
    private enum Field { case carbs, bg, units }
    @FocusState private var focus: Field?

    /// BG field binding that flags a user edit as `.manual` (auto-fills set `bg` directly + mark `.cgm`).
    private var bgField: Binding<String> {
        Binding(get: { bg }, set: { bg = $0; bgSource = $0.isEmpty ? .none : .manual })
    }
    /// Auto-fill the correction BG from the current CGM when the user hasn't typed their own and the
    /// reading is fresh; keeps it live as new readings arrive. No-op once the user edits the field.
    private func syncBGFromCGM() {
        guard bgSource != .manual, let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale else { return }
        let s = "\(g)"
        if bg != s { bg = s; bgSource = .cgm; if mode == .carbs { Task { await calculate() } } }
    }
    /// True when the shown dose leans on a CGM value that is now stale (advisory, not a block).
    private var staleCGMCorrection: Bool {
        mode == .carbs && bgSource == .cgm && model.snapshot.isGlucoseStale && (Int(bg) ?? 0) > 0
    }

    private var carbs: Double { Double(carbsText) ?? 0 }
    private var units: Double { Double(unitsText) ?? 0 }
    /// Advisory Smart Assist warnings for the current entry (empty unless the feature is on). Never blocks.
    private var smartWarnings: [String] {
        model.smartAssistWarnings(units: units, carbs: carbs, recommendedUnits: recommendation?.recommendedUnits)
    }
    /// Advisory (never blocks): the user has adjusted the dose away from the calculator's recommendation
    /// for a carb bolus, so the carbs recorded on the pump won't match the delivered units. Uses the same
    /// conservative 0.10 U limit as the remote divergence guard.
    private var carbOverrideWarning: String? {
        guard mode == .carbs, carbs > 0, let rec = recommendation, rec.recommendedUnits > 0,
              abs(units - rec.recommendedUnits) > AppModel.remoteDivergenceLimitUnits else { return nil }
        return String(format: "Delivering %.2f U for %.0f g — the calculator suggested %.2f U. The carbs will still be recorded on the pump with this dose.",
                      units, carbs, rec.recommendedUnits)
    }
    private var cgmAgeMinutes: Int? {
        model.snapshot.glucoseDate.map { max(0, Int(Date().timeIntervalSince($0) / 60)) }
    }
    /// "124 mg/dL · 2 min ago" for the live CGM readout on the bolus screen (nil when no reading).
    private var cgmReadout: String? {
        guard let g = model.snapshot.glucose else { return nil }
        guard let d = model.snapshot.glucoseDate else { return "\(g) mg/dL" }
        return "\(g) mg/dL · \(GlucoseFreshness.ageLabel(for: d, now: Date()))"
    }
    private var confirmMessage: String {
        var parts: [String] = []
        if staleCGMCorrection, let m = cgmAgeMinutes {
            parts.append("⚠️ Your CGM reading is \(m) min old — this correction may be based on outdated glucose.")
        }
        if let w = carbOverrideWarning { parts.append(w) }
        parts.append("faBolus is experimental and not FDA-cleared. Confirm the amount before you deliver.")
        return parts.joined(separator: "\n\n")
    }
    private var maxUnits: Double { model.snapshot.maxBolusUnits }
    private var overMax: Bool { units > maxUnits }

    /// Stepper bindings: read the numeric value, write formatted text (empty at zero → placeholder).
    private var carbsStep: Binding<Double> {
        Binding(get: { carbs }, set: { carbsText = $0 <= 0 ? "" : String(Int($0)) })
    }
    private var unitsStep: Binding<Double> {
        Binding(get: { units }, set: { unitsText = $0 <= 0 ? "" : Self.trimUnits($0) })
    }
    /// Compact units string: 1.00 → "1", 1.50 → "1.5", 0.05 → "0.05".
    private static func trimUnits(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var body: some View {
        Group {
            if embedded { content } else { NavigationStack { content } }
        }
    }

    private var content: some View {
        Form {
            // Carbs entry only when the active backend supports the pump's bolus calculator.
            if model.capabilities.supportsCarbEntry {
                Picker("Mode", selection: $mode) {
                    Text("Carbs").tag(BolusMode.carbs)
                    Text("Units").tag(BolusMode.units)
                }
                .pickerStyle(.segmented)
                .disabled(delivering || preparingDeliver)
            }

            if mode == .carbs {
                Section("Entry") {
                    HStack(spacing: 6) {
                        // The value + unit share one large tap target that focuses the field — the
                        // TextField itself is only ~one glyph wide (.fixedSize), so tapping the empty
                        // row space used to miss. Visuals are unchanged; only the hit area grows.
                        HStack(spacing: 6) {
                            TextField("0", text: $carbsText)
                                .keyboardType(.numberPad).fixedSize()
                                .font(.title3.weight(.semibold)).focused($focus, equals: .carbs)
                            Text("g carbs").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { focus = .carbs }
                        Stepper("", value: carbsStep, in: 0...300, step: settings.carbIncrement).labelsHidden()
                    }
                    LabeledContent("Blood glucose") {
                        TextField("mg/dL", text: bgField).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).focused($focus, equals: .bg)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { focus = .bg }
                    // Live CGM readout — refreshed on open and kept current while the screen is up.
                    if let readout = cgmReadout {
                        let stale = model.snapshot.isGlucoseStale
                        Label(readout, systemImage: stale ? "sensor.tag.radiowaves.forward" : "sensor.tag.radiowaves.forward.fill")
                            .font(.caption)
                            .foregroundStyle(stale ? .orange : .secondary)
                    }
                }
                if let rec = recommendation {
                    Section("Recommended") {
                        LabeledContent("Recommended dose", value: String(format: "%.2f U", rec.recommendedUnits)).fontWeight(.semibold)
                        if settings.showBolusReasoning {
                            DisclosureGroup("Show reasoning", isExpanded: $showReasoning) {
                                LabeledContent("Carb + correction", value: String(format: "%.2f U", rec.recommendedUnits + rec.iobUnits))
                                // DIF-ux: grey + age the IOB row when the active-insulin read is stale (or its
                                // age is unknown), via the shared `CalcInputFreshness` presentation — so the
                                // term the dose subtracts reads the same as a stale glucose row.
                                let iobStalePresent = CalcInputFreshness.iobPresentation(of: rec.iobDate) == .stale
                                let iobAge = rec.iobDate.map { CalcInputFreshness.ageLabel(for: $0) }
                                LabeledContent {
                                    Text(String(format: "−%.2f U", rec.iobUnits))
                                        .foregroundStyle(iobStalePresent ? AppTheme.low : .primary)
                                } label: {
                                    if iobStalePresent, let a = iobAge {
                                        Text("Active insulin (IOB) · \(a)").foregroundStyle(.orange)
                                    } else {
                                        Text("Active insulin (IOB)")
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Section("Deliver") {
                if delivering {
                    HStack { ProgressView(); Text("Delivering \(String(format: "%.2f U", units))…") }
                    if model.capabilities.supportsBolusCancel {
                        Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                            HStack { Spacer(); Label("Cancel bolus", systemImage: "stop.fill"); Spacer() }
                        }.buttonStyle(.borderedProminent).tint(.red)
                    }
                } else {
                    HStack(spacing: 6) {
                        // Enlarged tap target (see the carbs field) — visuals unchanged.
                        HStack(spacing: 6) {
                            TextField("0", text: $unitsText)
                                .keyboardType(.decimalPad).fixedSize()
                                .font(.title3.weight(.semibold)).focused($focus, equals: .units)
                                .foregroundStyle(overMax ? AppTheme.low : .primary)
                            Text("U").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { focus = .units }
                        Stepper("", value: unitsStep, in: 0...max(maxUnits, 0.01), step: settings.bolusIncrement).labelsHidden()
                    }
                    // §11 + Addendum B awareness: units mode showed NO CGM value/age (the readout lives in
                    // the carbs Entry section). A user dosing by units off a stale reading they mentally
                    // treat as current is a real hazard, so surface the same stale-styled readout here —
                    // ambient awareness, NOT a blocking confirm (nothing is silently dropped in units mode,
                    // and a modal on every units bolus would be alert fatigue).
                    if mode == .units, let readout = cgmReadout {
                        let staleR = model.snapshot.isGlucoseStale
                        Label(readout, systemImage: staleR ? "sensor.tag.radiowaves.forward" : "sensor.tag.radiowaves.forward.fill")
                            .font(.caption)
                            .foregroundStyle(staleR ? .orange : .secondary)
                    }
                    if overMax {
                        Label("Exceeds pump max of \(String(format: "%.1f", maxUnits)) U", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.low)
                    }
                    if !settings.childAllows(.bolus) {
                        Label("Bolus is disabled by child mode", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Group D: the shared gate surfaces pump-link / in-flight reasons the button used to
                    // grey silently (a disconnected or mid-delivery pump). overMax + child mode keep their
                    // dedicated labels above; bounds are self-evident from the entry field.
                    if let r = model.bolusGate(amount: units, minimum: 0.05).reason,
                       r == .pumpNotLinked || r == .bolusInFlight {
                        Label(r.userMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Smart Assist (advisory) — never blocks; the deliver button stays enabled.
                    ForEach(smartWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    // Dose overridden away from the carb recommendation (advisory; carbs still logged).
                    if let w = carbOverrideWarning {
                        Label(w, systemImage: "pencil.and.outline")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button { confirming = true } label: {
                        HStack { Spacer(); Text(preparingDeliver ? "Checking CGM…" : "Bolus \(String(format: "%.2f U", units))"); Spacer() }
                    }
                    .buttonStyle(.borderedProminent).tint(AppTheme.insulin)
                    .disabled(!model.bolusGate(amount: units, minimum: 0.05).canBolus || preparingDeliver)
                }
            }

            // Extended (combo) bolus — hidden unless enabled in Settings (keeps the screen simple) AND the
            // pump supports it (P13c-5 capability gate: don't offer a combo bolus a pump can't deliver).
            if settings.extendedBolusEnabled && model.capabilities.supportsExtendedBolus && !delivering {
                Section("Extended (combo) bolus") {
                    Stepper("Deliver now: \(extendedNowPercent)%", value: $extendedNowPercent, in: 0...100, step: 10)
                    Stepper("Over \(durationLabel(extendedDurationMin))", value: $extendedDurationMin, in: 30...480, step: 30)
                    let now = units * Double(extendedNowPercent) / 100
                    Text("\(String(format: "%.2f U", now)) now, \(String(format: "%.2f U", units - now)) over \(durationLabel(extendedDurationMin)). Min 0.40 U total.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button { confirmingExtended = true } label: {
                        HStack { Spacer(); Text("Extended bolus \(String(format: "%.2f U", units))"); Spacer() }
                    }
                    .buttonStyle(.bordered).tint(AppTheme.insulin)
                    .disabled(!model.bolusGate(amount: units, minimum: 0.4).canBolus || preparingDeliver)
                }
            }
        }
        .navigationTitle("Bolus")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !modeInitialized {
                mode = model.capabilities.supportsCarbEntry ? settings.defaultBolusMode : .units
                modeInitialized = true
            }
            // Pull the freshest CGM the moment the screen opens, then auto-fill the correction BG from
            // it (never from a stale value). The user can still type their own.
            if bg.isEmpty, let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale { bg = "\(g)"; bgSource = .cgm }
            if mode == .carbs { Task { await calculate() } }
            // DIF-core: pull the freshest CGM AND the freshest calc inputs (op-115 CR/ISF/target + op-109
            // IOB) the moment the screen opens, so the IOB/therapy the recommendation is built from are
            // fresh from the start (never the ~10-min-stale cache).
            Task { await model.refreshGlucoseNow(); await model.refreshCalcInputsNow(); syncBGFromCGM() }
        }
        // Recompute the recommendation live as carbs / BG change — no "Calculate" button needed.
        .onChange(of: carbsText) { _, _ in if mode == .carbs { Task { await calculate() } } }
        .onChange(of: bg) { _, _ in if mode == .carbs { Task { await calculate() } } }
        .onChange(of: mode) { _, newMode in if newMode == .carbs { Task { await calculate() } } }
        // Keep the CGM-sourced BG live as new readings arrive while the screen is open, and note when
        // the value changed so a just-landed reading (≤2 s before deliver) still triggers the re-check.
        .onChange(of: model.snapshot.glucoseDate) { _, _ in lastCGMChangeAt = Date(); syncBGFromCGM() }
        // Keep the reading current while the user is actively on the screen — WITHOUT hammering the
        // pump. Every 60 s we tick the age label, but only spend a pump read when the shown value is
        // actually aging (>90 s); otherwise the app-wide predictive poll has already refreshed it, so
        // there's zero extra BLE traffic. The loop self-stops after ~30 min so a screen left open by
        // accident can't drain battery or flood the pump, and it's cancelled outright when the screen
        // closes. `refreshGlucoseNow` itself no-ops unless the pump is connected (never during a bolus).
        .task {
            var ticks = 0
            while !Task.isCancelled && ticks < 30 {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                ticks += 1
                tick = Date()   // refresh the "N min ago" label
                if let d = model.snapshot.glucoseDate, Date().timeIntervalSince(d) > 90 {
                    await model.refreshGlucoseNow(); syncBGFromCGM()
                }
            }
        }
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .confirmationDialog("Deliver \(String(format: "%.2f U", units))?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Deliver \(String(format: "%.2f U", units))", role: .destructive) { Task { await attemptDeliver(extended: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .confirmationDialog(cgmUpdate?.newBG == -1 ? "CGM unavailable" : "CGM updated",
                            isPresented: Binding(get: { cgmUpdate != nil },
                                                 set: { if !$0 { cgmUpdate = nil } }),
                            titleVisibility: .visible) {
            if let u = cgmUpdate {
                if u.newBG == -1 {
                    // Addendum B three-way: (1) include the stale reading — insulin-INCREASING, recomputed
                    // WITH it — shown only when a stale reading exists; (2) carbs-only (drop the correction,
                    // today's behavior); (3) cancel (sends nothing — a pure UI back-out).
                    if let sbg = u.staleBG, let su = u.staleUnits {
                        Button("Include \(sbg) mg/dL → \(String(format: "%.2f U", su))") {
                            let ext = u.extended; cgmUpdate = nil
                            Task { await deliverFrozen(freeze(units: su, bg: sbg, extended: ext)) }
                        }
                    }
                    Button("Deliver \(String(format: "%.2f U", u.newUnits)) (carbs only)", role: .destructive) {
                        let ext = u.extended; cgmUpdate = nil
                        Task { await deliverFrozen(freeze(units: u.newUnits, bg: nil, extended: ext)) }
                    }
                    Button("Cancel", role: .cancel) { cgmUpdate = nil }
                } else {
                    Button("Use \(u.newBG) mg/dL → \(String(format: "%.2f U", u.newUnits))") {
                        bg = "\(u.newBG)"; bgSource = .cgm; unitsText = Self.trimUnits(u.newUnits)
                        let ext = u.extended; let bgv = u.newBG; let uu = u.newUnits; cgmUpdate = nil
                        Task { await deliverFrozen(freeze(units: uu, bg: bgv, extended: ext)) }
                    }
                    Button("Deliver \(String(format: "%.2f U", u.oldUnits)) anyway", role: .destructive) {
                        let ext = u.extended; let uu = u.oldUnits; let bgv = Int(bg); cgmUpdate = nil
                        Task { await deliverFrozen(freeze(units: uu, bg: bgv, extended: ext)) }
                    }
                    Button("Cancel", role: .cancel) { cgmUpdate = nil }
                }
            }
        } message: {
            if let u = cgmUpdate {
                if u.newBG == -1 {
                    if let sbg = u.staleBG {
                        Text("Your CGM reading (\(sbg) mg/dL) is stale and was left out of this dose. Include it in the correction, deliver carbs only (\(String(format: "%.2f U", u.newUnits))), or cancel.")
                    } else {
                        Text("No fresh CGM reading is available, so the correction can't be applied. Deliver the carbs-only dose (\(String(format: "%.2f U", u.newUnits))) or cancel.")
                    }
                } else {
                    Text("Your CGM changed while this dose was on screen. The new reading (\(u.newBG) mg/dL) suggests \(String(format: "%.2f U", u.newUnits)) instead of \(String(format: "%.2f U", u.oldUnits)).")
                }
            }
        }
        .confirmationDialog("Extended bolus \(String(format: "%.2f U", units))?",
                            isPresented: $confirmingExtended, titleVisibility: .visible) {
            Button("Deliver extended \(String(format: "%.2f U", units))", role: .destructive) { Task { await attemptDeliver(extended: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let now = units * Double(extendedNowPercent) / 100
            Text("\(String(format: "%.2f U", now)) now, then \(String(format: "%.2f U", units - now)) over \(durationLabel(extendedDurationMin)). faBolus is experimental and not FDA-cleared.")
        }
        // DIF-ux: the calc inputs weren't confirmed fresh this compose (`inputsVerified == false`). Present
        // the WARNED two-way override — never a silent deliver. `cancel` sends nothing. The "use / include"
        // button carries the exact dose it will deliver (recomputed off last-known values). No drop/zero-IOB
        // option exists (that is the maximum-dose direction — prohibited by the frozen owner decision).
        .confirmationDialog(calcInputDialogTitle,
                            isPresented: Binding(get: { calcInputPrompt != nil },
                                                 set: { if !$0 { calcInputPrompt = nil } }),
                            titleVisibility: .visible) {
            if let p = calcInputPrompt {
                Button(calcInputUseLabel(p), role: .destructive) {
                    // Accept the override for THIS attempt and RE-ENTER attemptDeliver — which now skips the
                    // warning gate but still runs the fresh-CGM refresh + divergence guard + Addendum-B
                    // stale-CGM three-way, with these flags threaded in. The button's dose is the baseline
                    // for the divergence comparison; the delivered dose is the deliver-time recompute.
                    acceptedOverride = AcceptedOverride(allowStaleIob: p.allowStaleIob,
                                                        allowStaleTherapy: p.allowStaleTherapy,
                                                        baseline: p.overrideUnits)
                    let ext = p.extended
                    calcInputPrompt = nil
                    Task { await attemptDeliver(extended: ext) }
                }
                Button("Cancel", role: .cancel) { calcInputPrompt = nil }   // sends NOTHING
            }
        } message: {
            if let p = calcInputPrompt { Text(calcInputMessage(p)) }
        }
    }

    // DIF-ux calc-input prompt copy (title / button / message), keyed on which input(s) were unconfirmed.
    private var calcInputDialogTitle: String {
        switch calcInputPrompt?.kind {
        case .iob:            return "Active insulin not confirmed"
        case .therapy:        return "Pump settings not confirmed"
        case .both, .none:    return "Pump inputs not confirmed"
        }
    }
    private func calcInputUseLabel(_ p: CalcInputPrompt) -> String {
        let dose = String(format: "%.2f U", p.overrideUnits)
        switch p.kind {
        case .iob:     return "Use last-known IOB → \(dose)"
        case .therapy: return "Use last-known settings → \(dose)"
        case .both:    return "Use last-known & deliver \(dose)"
        }
    }
    private func calcInputMessage(_ p: CalcInputPrompt) -> String {
        switch p.kind {
        case .iob:
            return StaleIobPrompt.warningMessage(iobUnits: p.iobUnits, iobDate: p.iobDate)
        case .therapy:
            return StaleTherapyPrompt.warningMessage(profile: p.assumedProfile, therapyDate: p.therapyDate)
        case .both:
            return StaleTherapyPrompt.warningMessage(profile: p.assumedProfile, therapyDate: p.therapyDate)
                + "\n\n" + StaleIobPrompt.warningMessage(iobUnits: p.iobUnits, iobDate: p.iobDate)
        }
    }

    private func durationLabel(_ min: Int) -> String {
        min % 60 == 0 ? "\(min / 60)h" : "\(min)m"
    }

    private func calculate() async {
        // Nothing entered yet → no recommendation card.
        guard carbs > 0 || (Int(bg) ?? 0) > 0 else { recommendation = nil; unitsText = ""; return }
        // Generation token (audit C-04): a newer edit supersedes this calc, so an out-of-order async
        // result can't overwrite the field with a stale dose.
        calcSeq &+= 1
        let seq = calcSeq
        calcInputPrompt = nil       // DIF-ux: a changed dose re-requires the per-attempt freshness override
        acceptedOverride = nil      // …and drops any override accepted for a prior compose
        let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: Int(bg))
        guard seq == calcSeq else { return }
        recommendation = rec
        unitsText = rec.recommendedUnits > 0 ? Self.trimUnits(rec.recommendedUnits) : ""
    }

    /// Immutable, confirmed bolus (audit C-04): captured once at confirm time; delivery uses exactly
    /// these values and never re-reads live `@State` that could change under it.
    private struct FrozenBolus { let units: Double; let carbsGrams: Double?; let bgMgdl: Int?; let iobUnits: Double?; let extendedNow: Double? ; let extendedDurationMin: Int? }

    /// Validate a correction against a FRESH CGM read, then freeze + deliver. Shared by the standard and
    /// extended paths (audit C-04 "same path"). For a CGM-based correction it pulls a fresh reading and:
    /// diverges → asks the user (cgmUpdate prompt); fresh & close → uses the fresh value; **stale/missing
    /// → fails closed** (drops the correction, delivers the carbs-only dose) rather than dosing off the
    /// stale on-screen value.
    private func attemptDeliver(extended: Bool) async {
        // DIF-ux: gate on `!inputsVerified` FIRST (BEFORE the CGM re-check), so the unconfirmed-but-in-window
        // case — `iobStale == therapyStale == false` yet `inputsVerified == false` — is still caught and can
        // never silently deliver. Present the WARNED two-way override, keyed on WHICH input(s) were
        // unconfirmed: therapy-only → use-last-known-settings; IOB-only → include-last-known-IOB; both, OR
        // neither flag but still unverified → the unified use-last-known override (both flags). `cancel`
        // sends nothing. Accepting sets `acceptedOverride` and RE-ENTERS this method, which then runs the
        // full deliver-time machinery below (fresh-CGM refresh + divergence guard + Addendum-B stale-CGM
        // three-way) with the override threaded in. Remotes never reach this — they fail closed in
        // `resolveRemoteDose`.
        // The gate fires ONLY in carbs-calculator mode, where the dose comes from the recommendation. In UNITS mode
        // the delivered amount is the number the user dialed, not a recommendation, so a lingering unverified
        // carb recommendation must never divert it into a carb-calc dose. Skip the gate once an override was
        // already accepted for this attempt (re-entry). The unconfirmed-but-in-window case
        // (`iobStale == therapyStale == false` yet `!inputsVerified`) is still caught. `cancel` sends nothing.
        if mode == .carbs, let rec = recommendation, !rec.inputsVerified,
           acceptedOverride == nil, calcInputPrompt == nil {
            let kind: CalcInputPrompt.Kind
            let allowIob: Bool, allowTherapy: Bool
            if rec.therapyStale && !rec.iobStale {
                kind = .therapy; allowIob = false; allowTherapy = true
            } else if rec.iobStale && !rec.therapyStale {
                kind = .iob; allowIob = true; allowTherapy = false
            } else {
                kind = .both; allowIob = true; allowTherapy = true   // both stale, or neither-flag-but-!verified
            }
            // Precompute the override dose off last-known values + the on-screen BG so the button shows the
            // estimate (the divergence BASELINE). The ACTUAL delivered dose is the deliver-time recompute
            // below off FRESH CGM, so a CGM move since compose is still caught by the divergence guard.
            let pre = await model.recommendBolus(carbsGrams: carbs, bgMgdl: Int(bg),
                                                 allowStaleIob: allowIob, allowStaleTherapy: allowTherapy)
            calcInputPrompt = CalcInputPrompt(kind: kind, extended: extended, overrideUnits: pre.recommendedUnits,
                                              allowStaleIob: allowIob, allowStaleTherapy: allowTherapy,
                                              iobUnits: rec.iobUnits, iobDate: rec.iobDate,
                                              assumedProfile: rec.assumedProfile, therapyDate: rec.therapyParamsDate)
            return
        }
        // Consume the accepted override (if any) for THIS attempt only, then clear it so it can never persist
        // to a later Deliver tap without a fresh warning (per-attempt). nil ⇒ the verified / normal path.
        let ov = acceptedOverride
        acceptedOverride = nil
        preparingDeliver = true
        defer { preparingDeliver = false }
        // Every CGM-sourced carbs-mode bolus routes here — meal+correction AND correction-only (carbs == 0).
        // A correction-only dose is still a BG correction off the CGM, so it MUST get the same deliver-time
        // fresh read + stale-CGM three-way as a meal bolus; gating this on `carbs > 0` previously let a
        // correction-only bolus (and a correction-only override) dose off a stale on-screen CGM value.
        if mode == .carbs, bgSource == .cgm {
            let justChanged = lastCGMChangeAt.map { Date().timeIntervalSince($0) <= 2 } ?? false
            // Divergence baseline: for an accepted override it's the dose the warned button showed (off the
            // compose-time BG); otherwise the on-screen `units`. Either way the guard fires on a real CGM
            // move between compose and deliver, not on the override's expected correction.
            let priorUnits = ov?.baseline ?? units
            await model.refreshGlucoseNow()
            // DIF-core: also force the calc inputs fresh right before the authoritative deliver-time
            // recompute, so the delivered dose is built from fresh CR/ISF/target + IOB. Because
            // `recommendBolus` re-reads fresh, the 0.10 U divergence guard below now also catches an INPUT
            // change (clinician edit / profile-segment boundary / IOB drift) between compose and deliver —
            // the recompute differs from the on-screen `priorUnits` and the CGM-updated prompt fires.
            // DIF-ux: any accepted override (`ov`) is threaded into EVERY recompute here, so last-known
            // IOB/therapy apply while this fresh-CGM / stale-CGM machinery still governs the glucose term.
            await model.refreshCalcInputsNow()
            if let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale {
                let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: g,
                                                     allowStaleIob: ov?.allowStaleIob ?? false,
                                                     allowStaleTherapy: ov?.allowStaleTherapy ?? false)
                let delta = abs(rec.recommendedUnits - priorUnits)
                if delta > AppModel.remoteDivergenceLimitUnits || (justChanged && delta > 0.0001) {
                    cgmUpdate = CGMUpdatePrompt(newBG: g, newUnits: rec.recommendedUnits, oldUnits: priorUnits, extended: extended)
                    return   // wait for the user's choice in the CGM-updated dialog
                }
                // FB-10: within tolerance we deliver exactly the on-screen dose (`priorUnits`, what the
                // Deliver button showed), so bind it to the BG it was actually computed from — NOT the
                // just-pulled `g`. Recording the fresh `g` against the old units would attach a glucose
                // value the dose wasn't derived from (a false pump/t:connect metadata pairing).
                await deliverFrozen(freeze(units: priorUnits, bg: Int(bg), extended: extended))
                return
            }
            // Addendum B: CGM stale/missing — never SILENTLY correct off the stale on-screen value, EVEN when
            // a stale-IOB/therapy override was accepted (the override covers those inputs, NOT glucose). Offer
            // the three-way choice (StaleBolusChoice: includeStale / proceedWithout / cancel). `newBG = -1`
            // selects the carbs-only branch of the dialog; when a stale-but-real reading exists, `staleBG`
            // adds the "include it" option (insulin-INCREASING, per-attempt, recomputed WITH the stale
            // value). With no reading at all there is nothing to include → carbs-only / cancel only. The
            // override is threaded into each offered dose so last-known IOB/therapy still apply.
            let carbsOnly = await model.recommendBolus(carbsGrams: carbs, bgMgdl: nil,
                                                       allowStaleIob: ov?.allowStaleIob ?? false,
                                                       allowStaleTherapy: ov?.allowStaleTherapy ?? false)
            if let sg = model.snapshot.glucose {   // we're in the stale branch, so a present reading is stale
                let withStale = await model.recommendBolus(carbsGrams: carbs, bgMgdl: sg,
                                                           allowStaleIob: ov?.allowStaleIob ?? false,
                                                           allowStaleTherapy: ov?.allowStaleTherapy ?? false)
                cgmUpdate = CGMUpdatePrompt(newBG: -1, newUnits: carbsOnly.recommendedUnits, oldUnits: priorUnits,
                                           extended: extended, staleBG: sg, staleUnits: withStale.recommendedUnits)
            } else {
                cgmUpdate = CGMUpdatePrompt(newBG: -1, newUnits: carbsOnly.recommendedUnits, oldUnits: priorUnits,
                                           extended: extended)
            }
            return
        }
        // No CGM-correction handling here: UNITS mode, or carbs mode with a manual/absent BG (bgSource !=
        // .cgm) — every CGM-sourced carbs dose took the branch above. In carbs mode with an accepted
        // override, deliver the override dose off the on-screen (manual/absent, so never "stale") BG +
        // last-known inputs, but NEVER MORE than the dose the warned button showed (`ov.baseline`, what the
        // owner consented to): a routine IOB poll landing between the button and accept must not silently
        // inflate the correction (op-109 decays → less IOB subtracted → a larger recompute). Delivering
        // min(baseline, fresh) never over-delivers vs either the consent or a fresh read (and the recompute
        // carries the divergence-max IOB guard). Otherwise (UNITS mode, or a verified carbs dose off manual
        // BG) freeze the on-screen values as-is — in UNITS mode that is exactly the number the user dialed.
        if mode == .carbs, let ov {
            let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: Int(bg),
                                                 allowStaleIob: ov.allowStaleIob, allowStaleTherapy: ov.allowStaleTherapy)
            await deliverFrozen(freeze(units: min(ov.baseline, rec.recommendedUnits), bg: Int(bg), extended: extended))
        } else {
            await deliverFrozen(freeze(units: units, bg: Int(bg), extended: extended))
        }
    }

    /// Build the immutable proposal from confirmed values.
    private func freeze(units u: Double, bg bgVal: Int?, extended: Bool) -> FrozenBolus {
        // FB-04: freeze the calculator IOB the recommendation used, so it's the value recorded on the
        // pump as bolusIOB metadata — not a live snapshot read at delivery time.
        FrozenBolus(units: u, carbsGrams: carbs > 0 ? carbs : nil, bgMgdl: bgVal,
                    iobUnits: recommendation?.iobUnits,
                    extendedNow: extended ? u * Double(extendedNowPercent) / 100 : nil,
                    extendedDurationMin: extended ? extendedDurationMin : nil)
    }

    /// Deliver exactly the frozen proposal — the only place that calls the backend (audit C-04).
    private func deliverFrozen(_ f: FrozenBolus) async {
        delivering = true
        if let now = f.extendedNow, let dur = f.extendedDurationMin {
            await model.deliverExtendedBolus(totalUnits: f.units, nowUnits: now, durationMinutes: dur,
                                             carbsGrams: f.carbsGrams, bgMgdl: f.bgMgdl, iobUnits: f.iobUnits)
        } else {
            // Carbs/BG go to the pump as recorded metadata (graph / t:connect / Control-IQ) and are logged
            // locally for the smart features — carb recording is centralized in the model.
            await model.deliverBolus(units: f.units, carbsGrams: f.carbsGrams, bgMgdl: f.bgMgdl, iobUnits: f.iobUnits)
        }
        delivering = false
        finishDelivery()
    }

    private func finishDelivery() {
        if embedded {
            unitsText = ""; carbsText = ""; recommendation = nil   // reset for the next one
        } else {
            dismiss()
        }
    }
}
