import SwiftUI

/// Bolus entry (Loop-style). Carbs (+ optional BG) → recommended dose, or a plain Units dial —
/// default mode and the ± increments come from Settings. SALINE bench boluses only; enforces the
/// max-units interlock and an explicit confirm. Works as a tab (`embedded`) or a sheet.
struct BolusEntryView: View {
    let model: AppModel
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared

    @State private var mode: BolusMode = .carbs
    @State private var modeInitialized = false
    @State private var carbs = 0.0
    @State private var bg = ""
    @State private var units = 0.0
    @State private var recommendation: BolusRecommendation?
    @State private var confirming = false
    @State private var delivering = false

    private var maxUnits: Double { model.snapshot.maxBolusUnits }
    private var overMax: Bool { units > maxUnits }

    var body: some View {
        Group {
            if embedded { content } else { NavigationStack { content } }
        }
    }

    private var content: some View {
        Form {
            Picker("Mode", selection: $mode) {
                Text("Carbs").tag(BolusMode.carbs)
                Text("Units").tag(BolusMode.units)
            }
            .pickerStyle(.segmented)
            .disabled(delivering)

            if mode == .carbs {
                Section("Entry") {
                    Stepper(value: $carbs, in: 0...300, step: settings.carbIncrement) {
                        Text("\(Int(carbs)) g carbs").font(.title3.weight(.semibold))
                    }
                    LabeledContent("Blood glucose") {
                        TextField("mg/dL", text: $bg).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Button("Calculate recommendation") { Task { await calculate() } }
                }
                if let rec = recommendation {
                    Section("Recommended") {
                        LabeledContent("Carb + correction", value: String(format: "%.2f U", rec.recommendedUnits + rec.iobUnits))
                        LabeledContent("Active insulin (IOB)", value: String(format: "−%.2f U", rec.iobUnits))
                        LabeledContent("Recommended dose", value: String(format: "%.2f U", rec.recommendedUnits)).fontWeight(.semibold)
                    }
                }
            }

            Section("Deliver (saline, bench)") {
                if delivering {
                    HStack { ProgressView(); Text("Delivering \(String(format: "%.2f U", units))…") }
                    Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                        HStack { Spacer(); Label("Cancel bolus", systemImage: "stop.fill"); Spacer() }
                    }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Stepper(value: $units, in: 0...max(maxUnits, 0.01), step: settings.bolusIncrement) {
                        Text(String(format: "%.2f U", units)).font(.title3.weight(.semibold))
                            .foregroundStyle(overMax ? LoopTheme.low : .primary)
                    }
                    if overMax {
                        Label("Exceeds pump max of \(String(format: "%.1f", maxUnits)) U", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LoopTheme.low)
                    }
                    Button { confirming = true } label: {
                        HStack { Spacer(); Text("Bolus \(String(format: "%.2f U", units))"); Spacer() }
                    }
                    .buttonStyle(.borderedProminent).tint(LoopTheme.insulin)
                    .disabled(units < 0.05 || overMax || model.snapshot.connection != .connected)
                }
            }
        }
        .navigationTitle("Bolus")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !modeInitialized { mode = settings.defaultBolusMode; modeInitialized = true }
            if bg.isEmpty, let g = model.snapshot.glucose { bg = "\(g)" }
        }
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .confirmationDialog("Deliver \(String(format: "%.2f U", units)) of SALINE?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Deliver \(String(format: "%.2f U", units))", role: .destructive) { Task { await deliver() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bench proof-of-concept. Confirm the pump is dispensing saline into a container on a scale — never on a body.")
        }
    }

    private func calculate() async {
        let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: Int(bg))
        recommendation = rec
        units = rec.recommendedUnits
    }

    private func deliver() async {
        delivering = true
        await model.deliverBolus(units: units)
        delivering = false
        if embedded {
            units = 0; carbs = 0; recommendation = nil   // reset for the next one
        } else {
            dismiss()
        }
    }
}
