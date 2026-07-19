import SwiftUI

/// Loop-style bolus entry: enter carbs (+ optional BG), get a recommended dose, adjust, and
/// confirm. SALINE bench boluses only. Enforces the max-units interlock and an explicit
/// confirm step.
struct BolusEntryView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var carbs = ""
    @State private var bg = ""
    @State private var units = 0.0
    @State private var recommendation: BolusRecommendation?
    @State private var confirming = false
    @State private var delivering = false

    private var overMax: Bool { units > Interlocks.maxBolusUnits }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    LabeledContent("Carbs") {
                        TextField("grams", text: $carbs)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Blood glucose") {
                        TextField("mg/dL (optional)", text: $bg)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Button("Calculate recommendation") { Task { await calculate() } }
                }

                if let rec = recommendation {
                    Section("Recommended") {
                        LabeledContent("Carb + correction", value: String(format: "%.2f U", rec.recommendedUnits + rec.iobUnits))
                        LabeledContent("Active insulin (IOB)", value: String(format: "−%.2f U", rec.iobUnits))
                        LabeledContent("Recommended dose", value: String(format: "%.2f U", rec.recommendedUnits))
                            .fontWeight(.semibold)
                    }
                }

                Section("Deliver (saline, bench)") {
                    Stepper(value: $units, in: 0...Interlocks.maxBolusUnits, step: 0.05) {
                        Text(String(format: "%.2f U", units))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(overMax ? LoopTheme.low : .primary)
                    }
                    if overMax {
                        Label("Exceeds max of \(Int(Interlocks.maxBolusUnits)) U", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LoopTheme.low)
                    }
                    Button {
                        confirming = true
                    } label: {
                        HStack { Spacer(); Text("Bolus \(String(format: "%.2f U", units))"); Spacer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LoopTheme.insulin)
                    .disabled(units < 0.05 || overMax || delivering)
                }
            }
            .navigationTitle("Bolus")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Deliver \(String(format: "%.2f U", units)) of SALINE?",
                                isPresented: $confirming, titleVisibility: .visible) {
                Button("Deliver \(String(format: "%.2f U", units))", role: .destructive) {
                    Task { await deliver() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Bench proof-of-concept. Confirm the pump is dispensing saline into a container on a scale — never on a body.")
            }
        }
    }

    private func calculate() async {
        let c = Double(carbs) ?? 0
        let b = Int(bg)
        let rec = await model.recommendBolus(carbsGrams: c, bgMgdl: b)
        recommendation = rec
        units = rec.recommendedUnits
    }

    private func deliver() async {
        delivering = true
        await model.deliverBolus(units: units)
        delivering = false
        dismiss()
    }
}
