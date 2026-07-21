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
    private enum Field { case carbs, bg, units }
    @FocusState private var focus: Field?

    private var carbs: Double { Double(carbsText) ?? 0 }
    private var units: Double { Double(unitsText) ?? 0 }
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
                        TextField("0", text: $carbsText)
                            .keyboardType(.numberPad).fixedSize()
                            .font(.title3.weight(.semibold)).focused($focus, equals: .carbs)
                        Text("g carbs").foregroundStyle(.secondary)
                        Spacer()
                        Stepper("", value: carbsStep, in: 0...300, step: settings.carbIncrement).labelsHidden()
                    }
                    LabeledContent("Blood glucose") {
                        TextField("mg/dL", text: $bg).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).focused($focus, equals: .bg)
                    }
                    Button("Calculate recommendation") { Task { await calculate() } }
                }
                if let rec = recommendation {
                    Section("Recommended") {
                        LabeledContent("Recommended dose", value: String(format: "%.2f U", rec.recommendedUnits)).fontWeight(.semibold)
                        Button("Use") { unitsText = Self.trimUnits(rec.recommendedUnits) }.font(.caption)
                        if settings.showBolusReasoning {
                            DisclosureGroup("Show reasoning", isExpanded: $showReasoning) {
                                LabeledContent("Carb + correction", value: String(format: "%.2f U", rec.recommendedUnits + rec.iobUnits))
                                LabeledContent("Active insulin (IOB)", value: String(format: "−%.2f U", rec.iobUnits))
                                if let maxSafe = rec.maxSafeUnits {
                                    LabeledContent("Max safe (est.)", value: String(format: "%.2f U", maxSafe))
                                        .foregroundStyle(units > maxSafe ? AppTheme.low : .secondary)
                                    Text("Advisory: a larger dose could take you below target given current BG, ISF, and IOB. Not a limit.")
                                        .font(.caption2).foregroundStyle(.secondary)
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
                        TextField("0", text: $unitsText)
                            .keyboardType(.decimalPad).fixedSize()
                            .font(.title3.weight(.semibold)).focused($focus, equals: .units)
                            .foregroundStyle(overMax ? AppTheme.low : .primary)
                        Text("U").foregroundStyle(.secondary)
                        Spacer()
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
            // Never auto-fill the correction BG from a stale CGM value (see GlucoseFreshness.staleAfter).
            // The user can still type one in manually.
            if bg.isEmpty, let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale { bg = "\(g)" }
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
            Button("Deliver \(String(format: "%.2f U", units))", role: .destructive) { Task { await deliver() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("faBolus is experimental and not FDA-cleared. Confirm the amount before you deliver.")
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
        let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: Int(bg))
        recommendation = rec
        unitsText = rec.recommendedUnits > 0 ? Self.trimUnits(rec.recommendedUnits) : ""
    }

    private func deliver() async {
        delivering = true
        await model.deliverBolus(units: units)
        delivering = false
        finishDelivery()
    }

    private func deliverExtended() async {
        delivering = true
        let now = units * Double(extendedNowPercent) / 100
        await model.deliverExtendedBolus(totalUnits: units, nowUnits: now, durationMinutes: extendedDurationMin)
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
