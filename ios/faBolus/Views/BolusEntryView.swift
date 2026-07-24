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
    private struct CGMUpdatePrompt: Identifiable { let id = UUID(); let newBG: Int; let newUnits: Double; let oldUnits: Double; let extended: Bool }
    /// Supersedes out-of-order async recommendation results (audit C-04).
    @State private var calcSeq = 0
    /// FB-01: when the recommendation was computed from ASSUMED (unverified) pump settings, delivery
    /// requires a distinct blocking acknowledgement of those assumed CR/ISF/target values first. Reset on
    /// every recompute so each new dose re-requires the ack.
    @State private var pendingAssumed: (extended: Bool, profile: BolusMath.Profile)?
    @State private var assumedAcknowledged = false
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
                                LabeledContent("Active insulin (IOB)", value: String(format: "−%.2f U", rec.iobUnits))
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
                    if overMax {
                        Label("Exceeds pump max of \(String(format: "%.1f", maxUnits)) U", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.low)
                    }
                    if !settings.childAllows(.bolus) {
                        Label("Bolus is disabled by child mode", systemImage: "lock.fill")
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
                    .disabled(units < 0.05 || overMax || model.snapshot.connection != .connected || !settings.childAllows(.bolus) || preparingDeliver)
                }
            }

            // Extended (combo) bolus — hidden unless enabled in Settings (keeps the screen simple).
            if settings.extendedBolusEnabled && !delivering {
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
                    .disabled(units < 0.4 || overMax || model.snapshot.connection != .connected || !settings.childAllows(.bolus) || preparingDeliver)
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
            Task { await model.refreshGlucoseNow(); syncBGFromCGM() }
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
                    // No fresh CGM — the only safe options are the carbs-only dose or cancel.
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
                    Text("No fresh CGM reading is available, so the correction can't be applied. Deliver the carbs-only dose (\(String(format: "%.2f U", u.newUnits))) or cancel.")
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
        // FB-01: assumed-settings acknowledgement — the pump's verified profile hasn't arrived, so the
        // dose used ASSUMED values. Force the user to see and accept them before anything is delivered.
        .confirmationDialog("Pump settings not verified",
                            isPresented: Binding(get: { pendingAssumed != nil },
                                                 set: { if !$0 { pendingAssumed = nil } }),
                            titleVisibility: .visible) {
            if let p = pendingAssumed {
                Button("Use assumed settings & deliver \(String(format: "%.2f U", units))", role: .destructive) {
                    let ext = p.extended; pendingAssumed = nil; assumedAcknowledged = true
                    Task { await attemptDeliver(extended: ext) }
                }
                Button("Cancel", role: .cancel) { pendingAssumed = nil }
            }
        } message: {
            if let p = pendingAssumed {
                Text("faBolus hasn't read this pump's bolus settings yet, so this dose assumes carb ratio \(String(format: "%.0f", p.profile.carbRatioGramsPerUnit)) g/U, ISF \(p.profile.isfMgdlPerUnit), target \(p.profile.targetBgMgdl) mg/dL and ignores BG correction. Only continue if those match your pump.")
            }
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
        assumedAcknowledged = false   // FB-01: a changed dose must re-acknowledge assumed settings
        let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: Int(bg))
        guard seq == calcSeq else { return }
        recommendation = rec
        unitsText = rec.recommendedUnits > 0 ? Self.trimUnits(rec.recommendedUnits) : ""
    }

    /// Immutable, confirmed bolus (audit C-04): captured once at confirm time; delivery uses exactly
    /// these values and never re-reads live `@State` that could change under it.
    private struct FrozenBolus { let units: Double; let carbsGrams: Double?; let bgMgdl: Int?; let extendedNow: Double? ; let extendedDurationMin: Int? }

    /// Validate a correction against a FRESH CGM read, then freeze + deliver. Shared by the standard and
    /// extended paths (audit C-04 "same path"). For a CGM-based correction it pulls a fresh reading and:
    /// diverges → asks the user (cgmUpdate prompt); fresh & close → uses the fresh value; **stale/missing
    /// → fails closed** (drops the correction, delivers the carbs-only dose) rather than dosing off the
    /// stale on-screen value.
    private func attemptDeliver(extended: Bool) async {
        // FB-01: never deliver a dose computed from ASSUMED pump settings without an explicit, distinct
        // acknowledgement of the assumed CR/ISF/target — separate from the generic dose confirm.
        if let rec = recommendation, !rec.inputsVerified, let ap = rec.assumedProfile, !assumedAcknowledged {
            pendingAssumed = (extended, ap)
            return
        }
        preparingDeliver = true
        defer { preparingDeliver = false }
        if mode == .carbs, bgSource == .cgm, carbs > 0 {
            let justChanged = lastCGMChangeAt.map { Date().timeIntervalSince($0) <= 2 } ?? false
            let priorUnits = units
            await model.refreshGlucoseNow()
            if let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale {
                let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: g)
                let delta = abs(rec.recommendedUnits - priorUnits)
                if delta > AppModel.remoteDivergenceLimitUnits || (justChanged && delta > 0.0001) {
                    cgmUpdate = CGMUpdatePrompt(newBG: g, newUnits: rec.recommendedUnits, oldUnits: priorUnits, extended: extended)
                    return   // wait for the user's choice in the CGM-updated dialog
                }
                await deliverFrozen(freeze(units: priorUnits, bg: g, extended: extended))
                return
            }
            // Fail closed: CGM stale/missing — never correct off the stale on-screen value. Deliver the
            // carbs-only dose after the user confirms (newBG = -1 signals "no fresh CGM" in the dialog).
            let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: nil)
            cgmUpdate = CGMUpdatePrompt(newBG: -1, newUnits: rec.recommendedUnits, oldUnits: priorUnits, extended: extended)
            return
        }
        // No CGM correction (units mode, manual BG, or no carbs): freeze the on-screen values as-is.
        await deliverFrozen(freeze(units: units, bg: Int(bg), extended: extended))
    }

    /// Build the immutable proposal from confirmed values.
    private func freeze(units u: Double, bg bgVal: Int?, extended: Bool) -> FrozenBolus {
        FrozenBolus(units: u, carbsGrams: carbs > 0 ? carbs : nil, bgMgdl: bgVal,
                    extendedNow: extended ? u * Double(extendedNowPercent) / 100 : nil,
                    extendedDurationMin: extended ? extendedDurationMin : nil)
    }

    /// Deliver exactly the frozen proposal — the only place that calls the backend (audit C-04).
    private func deliverFrozen(_ f: FrozenBolus) async {
        delivering = true
        if let now = f.extendedNow, let dur = f.extendedDurationMin {
            await model.deliverExtendedBolus(totalUnits: f.units, nowUnits: now, durationMinutes: dur,
                                             carbsGrams: f.carbsGrams, bgMgdl: f.bgMgdl)
        } else {
            // Carbs/BG go to the pump as recorded metadata (graph / t:connect / Control-IQ) and are logged
            // locally for the smart features — carb recording is centralized in the model.
            await model.deliverBolus(units: f.units, carbsGrams: f.carbsGrams, bgMgdl: f.bgMgdl)
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
