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
    /// Set when a fresh CGM pulled at delivery time would change the dose — asks the user which to use.
    @State private var cgmUpdate: CGMUpdatePrompt?
    private struct CGMUpdatePrompt: Identifiable { let id = UUID(); let newBG: Int; let newUnits: Double; let oldUnits: Double }
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
                .disabled(delivering)
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
                        HStack { Spacer(); Text("Bolus \(String(format: "%.2f U", units))"); Spacer() }
                    }
                    .buttonStyle(.borderedProminent).tint(AppTheme.insulin)
                    .disabled(units < 0.05 || overMax || model.snapshot.connection != .connected || !settings.childAllows(.bolus))
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
                    .disabled(units < 0.4 || overMax || model.snapshot.connection != .connected || !settings.childAllows(.bolus))
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
        // Keep the CGM-sourced BG live as new readings arrive while the screen is open.
        .onChange(of: model.snapshot.glucoseDate) { _, _ in syncBGFromCGM() }
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .confirmationDialog("Deliver \(String(format: "%.2f U", units))?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Deliver \(String(format: "%.2f U", units))", role: .destructive) { Task { await attemptDeliver() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .confirmationDialog("CGM updated", isPresented: Binding(get: { cgmUpdate != nil },
                                                               set: { if !$0 { cgmUpdate = nil } }),
                            titleVisibility: .visible) {
            if let u = cgmUpdate {
                Button("Use \(u.newBG) mg/dL → \(String(format: "%.2f U", u.newUnits))") {
                    bg = "\(u.newBG)"; bgSource = .cgm; unitsText = Self.trimUnits(u.newUnits)
                    cgmUpdate = nil; Task { await deliver() }
                }
                Button("Deliver \(String(format: "%.2f U", u.oldUnits)) anyway", role: .destructive) {
                    cgmUpdate = nil; Task { await deliver() }
                }
                Button("Cancel", role: .cancel) { cgmUpdate = nil }
            }
        } message: {
            if let u = cgmUpdate {
                Text("Your CGM changed while this dose was on screen. The new reading (\(u.newBG) mg/dL) suggests \(String(format: "%.2f U", u.newUnits)) instead of \(String(format: "%.2f U", u.oldUnits)).")
            }
        }
        .confirmationDialog("Extended bolus \(String(format: "%.2f U", units))?",
                            isPresented: $confirmingExtended, titleVisibility: .visible) {
            Button("Deliver extended \(String(format: "%.2f U", units))", role: .destructive) { Task { await deliverExtended() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let now = units * Double(extendedNowPercent) / 100
            Text("\(String(format: "%.2f U", now)) now, then \(String(format: "%.2f U", units - now)) over \(durationLabel(extendedDurationMin)). faBolus is experimental and not FDA-cleared.")
        }
    }

    private func durationLabel(_ min: Int) -> String {
        min % 60 == 0 ? "\(min / 60)h" : "\(min)m"
    }

    private func calculate() async {
        // Nothing entered yet → no recommendation card.
        guard carbs > 0 || (Int(bg) ?? 0) > 0 else { recommendation = nil; unitsText = ""; return }
        let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: Int(bg))
        recommendation = rec
        unitsText = rec.recommendedUnits > 0 ? Self.trimUnits(rec.recommendedUnits) : ""
    }

    /// Pull the freshest CGM right before delivering. If the correction leans on the CGM and the new
    /// value would change the dose by more than the safety limit, ask the user which value to use
    /// (via the `cgmUpdate` prompt) instead of silently delivering the stale-based dose.
    private func attemptDeliver() async {
        if mode == .carbs, bgSource == .cgm, carbs > 0 {
            preparingDeliver = true
            await model.refreshGlucoseNow()
            preparingDeliver = false
            if let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale {
                let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: g)
                if abs(rec.recommendedUnits - units) > AppModel.remoteDivergenceLimitUnits {
                    cgmUpdate = CGMUpdatePrompt(newBG: g, newUnits: rec.recommendedUnits, oldUnits: units)
                    return   // wait for the user's choice in the CGM-updated dialog
                }
            }
        }
        await deliver()
    }

    private func deliver() async {
        delivering = true
        // Carbs/BG go to the pump as recorded metadata (graph / t:connect / Control-IQ) and are logged
        // locally for the smart features — carb recording is centralized in the model now.
        await model.deliverBolus(units: units, carbsGrams: carbs > 0 ? carbs : nil, bgMgdl: Int(bg))
        delivering = false
        finishDelivery()
    }

    private func deliverExtended() async {
        delivering = true
        let now = units * Double(extendedNowPercent) / 100
        await model.deliverExtendedBolus(totalUnits: units, nowUnits: now, durationMinutes: extendedDurationMin,
                                         carbsGrams: carbs > 0 ? carbs : nil, bgMgdl: Int(bg))
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
