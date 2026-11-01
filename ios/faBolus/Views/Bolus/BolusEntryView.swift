import PhoneApp
import PumpSession
import SwiftUI
import faBolusCore
import faBolusDesign

/// The bolus screen. Carbs (with the pump's calculator) or units; Confirm reads the dose inputs fresh from
/// the pump, asks what the dose code asks, and shows the dose with its notices before it's sent.
struct BolusEntryView: View {
    @Bindable var model: AppModel
    @State private var flow: BolusFlow?
    var initialFlow: BolusFlow?
    @State private var showReasoning = false
    @FocusState private var focus: Field?

    enum Field { case carbs, glucose, units }

    var body: some View {
        Group {
            if let flow = flow ?? initialFlow { form(flow) } else { ProgressView() }
        }
        .navigationTitle("Bolus")
        .onAppear {
            guard flow == nil else { return }
            let made = initialFlow ?? BolusFlow(model: model)
            // A paired pump that takes no carbs has no mode picker, so the screen is in units for it.
            if !takesCarbs { made.mode = .units }
            flow = made
        }
        .onChange(of: takesCarbs) { _, carbs in flow?.mode = carbs ? model.settings.defaultBolusMode : .units }
    }

    @ViewBuilder private func form(_ flow: BolusFlow) -> some View {
        @Bindable var flow = flow
        Form {
            if takesCarbs {
                Picker("Mode", selection: $flow.mode) {
                    Text("Carbs").tag(BolusEntryMode.carbs)
                    Text("Units").tag(BolusEntryMode.units)
                }
                .pickerStyle(.segmented)
                .onChange(of: flow.mode) { _, _ in flow.entryChanged() }
            }
            if flow.mode == .carbs {
                Section("Entry") {
                    HStack {
                        TextField("0", text: $flow.carbsText).keyboardType(.numberPad).font(.title3.weight(.semibold))
                            .focused($focus, equals: .carbs).accessibilityLabel("Carbs, grams")
                        Text("g carbs").foregroundStyle(.secondary)
                        Stepper("", value: carbsStep(flow), in: 0...999, step: Double(model.settings.carbIncrement))
                            .labelsHidden().accessibilityLabel("Carbs")
                    }
                    LabeledContent("Glucose") {
                        TextField(placeholder(flow), text: $flow.glucoseText).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).focused($focus, equals: .glucose)
                            .accessibilityLabel("Blood glucose, mg/dL")
                    }
                    cgmLine(flow)
                }
                .onChange(of: flow.carbsText) { _, _ in flow.entryChanged() }
                .onChange(of: flow.glucoseText) { _, _ in flow.entryChanged() }
                recommendation(flow)
            }
            Section("Dose") {
                HStack {
                    TextField(
                        "0",
                        text: Binding(get: { flow.unitsText }, set: { flow.unitsTyped($0) })
                    )
                    .keyboardType(.decimalPad).font(.title3.weight(.semibold)).focused($focus, equals: .units)
                    .accessibilityLabel("Bolus, units")
                    Text("U").foregroundStyle(.secondary)
                    Stepper("", value: unitsStep(flow), in: 0...100, step: model.settings.bolusIncrement)
                        .labelsHidden().accessibilityLabel("Bolus units")
                }
                if flow.mode == .units { cgmLine(flow) }
                if let reason = flow.blockingReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(
                        .secondary)
                }
                Button {
                    focus = nil
                    Task { await flow.confirm() }
                } label: {
                    HStack {
                        Spacer()
                        if flow.phase == .composing {
                            ProgressView()
                        } else {
                            Text("Confirm \(flow.units.map { formatUnits($0) } ?? "")")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.insulin)
                .disabled(flow.unavailableReason != nil || flow.phase != .editing)
            }
            if let status = model.latestOutcome, status.outcome.isInFlight {
                Section {
                    BolusBannerView(banner: BolusBanner.make(status.outcome, requestedUnits: status.requestedUnits))
                }
            }
            if case .refused(let message) = flow.phase {
                Section {
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(AppTheme.low)
                    Button("OK") { flow.dismissResult() }
                }
            }
            if case .done(let result) = flow.phase, let message = Self.text(result) {
                Section {
                    Text(message)
                    Button("OK") { flow.dismissResult() }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .sheet(item: reviewBinding(flow)) { review in
            BolusReviewSheet(dose: review.dose, notices: BolusFlow.notices(review.dose)) {
                Task { await flow.deliver() }
            } onCancel: {
                flow.cancel()
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            promptTitle(flow), isPresented: promptShowing(flow), titleVisibility: .visible,
            presenting: promptValue(flow)
        ) { prompt in
            ForEach(Array(flow.text(for: prompt).choices.enumerated()), id: \.offset) { _, choice in
                Button(choice.1) { flow.choose(choice.0) }
            }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { prompt in
            Text(flow.text(for: prompt).message)
        }
    }

    private var takesCarbs: Bool { model.display.capabilities.supportsCarbEntry || model.pairing == nil }

    private func placeholder(_ flow: BolusFlow) -> String {
        flow.currentReading.map { "CGM \(model.settings.glucoseUnit.format(mgdl: $0))" } ?? "mg/dL"
    }

    @ViewBuilder private func cgmLine(_ flow: BolusFlow) -> some View {
        let display = model.pumpDisplay(now: model.now)
        switch display.glucose {
        case .current(let mgdl, _, let at):
            Label(
                "CGM \(display.unit.format(mgdl: mgdl)) mg/dL, \(display.age(at))",
                systemImage: "sensor.tag.radiowaves.forward.fill"
            )
            .font(.caption).foregroundStyle(.secondary)
        case .stale(let mgdl, _, let at):
            Label(
                "CGM \(display.unit.format(mgdl: mgdl)) mg/dL is \(display.age(at)): not used for a correction",
                systemImage: "sensor.tag.radiowaves.forward"
            )
            .font(.caption).foregroundStyle(.orange)
        case .hidden, .none:
            Label("No current CGM reading", systemImage: "sensor.tag.radiowaves.forward").font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func recommendation(_ flow: BolusFlow) -> some View {
        let r = flow.recommendation
        Section("Suggested") {
            if !r.glucoseIsPlausible {
                Label(
                    "That glucose looks out of range. Re-check it before dosing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(AppTheme.low)
            }
            if r.displaysNumericDose {
                LabeledContent("Suggested dose", value: formatUnits(r.units)).fontWeight(.semibold)
                if model.settings.showBolusReasoning, let c = r.calculation {
                    DisclosureGroup("Show the calculation", isExpanded: $showReasoning) {
                        LabeledContent("Carbs", value: formatUnits(c.fromCarbs))
                        LabeledContent("Correction", value: formatUnits(c.fromBG))
                        LabeledContent("Active insulin", value: "−" + formatUnits(c.fromIOB))
                        if !r.inputs.isVerified {
                            Text("faBolus reads the pump's settings and active insulin again when you confirm.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Label("Waiting for the pump's bolus settings and active insulin…", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func carbsStep(_ flow: BolusFlow) -> Binding<Double> {
        Binding(
            get: { flow.carbs ?? 0 },
            set: {
                flow.carbsText = String(Int($0))
                flow.entryChanged()
            })
    }

    private func unitsStep(_ flow: BolusFlow) -> Binding<Double> {
        Binding(get: { flow.units ?? 0 }, set: { flow.unitsTyped(String(format: "%.2f", max(0, $0))) })
    }

    private struct Review: Identifiable {
        let dose: ComposedDose
        var id: String { dose.request.id }
    }

    private func reviewBinding(_ flow: BolusFlow) -> Binding<Review?> {
        Binding(
            get: {
                if case .review(let dose) = flow.phase { return Review(dose: dose) }
                return nil
            },
            set: { if $0 == nil, case .review = flow.phase { flow.cancel() } })
    }

    private func promptValue(_ flow: BolusFlow) -> PhoneDosePrompt? {
        if case .prompt(let p) = flow.phase { return p }
        return nil
    }

    private func promptShowing(_ flow: BolusFlow) -> Binding<Bool> {
        Binding(get: { promptValue(flow) != nil }, set: { if !$0, promptValue(flow) != nil { flow.cancel() } })
    }

    private func promptTitle(_ flow: BolusFlow) -> String { promptValue(flow).map { flow.text(for: $0).title } ?? "" }

    static func text(_ result: DeliveryResult) -> String? {
        switch result {
        case .started: return nil
        case .alreadyRecorded(let outcome): return BolusBanner.make(outcome, requestedUnits: nil).title
        case .notStarted(let refusal): return PumpMessages.text(refusal)
        }
    }
}

/// The last look before a dose is sent: the dose, what it's for, and its notices above the button.
struct BolusReviewSheet: View {
    let dose: ComposedDose
    let notices: [String]
    let onDeliver: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(formatUnits(dose.units)).font(.system(size: 44, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    if let carbs = dose.request.carbsGrams, carbs > 0 { Text("For \(Int(carbs)) g carbs") }
                    if let bg = dose.correctionGlucoseMgdl { Text("Correcting from \(bg) mg/dL") }
                    if let iob = dose.calculatorIOBUnits { Text("Active insulin \(formatUnits(iob))") }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Spacer()
                // The sheet closes when the flow leaves the review; dismissing here first would read as a cancel.
                Button {
                    onDeliver()
                } label: {
                    Text("Deliver \(formatUnits(dose.units))").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.insulin).controlSize(.large)
            }
            .padding()
            .navigationTitle("Deliver bolus?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
