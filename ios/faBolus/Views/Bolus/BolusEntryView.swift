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
        .sensoryFeedback(.warning, trigger: flow?.changeAlert) { _, new in new != nil }
        .navigationTitle("Bolus")
        // Inline, with compact cards and no section headers, so the screen fits without scrolling.
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard flow == nil else { return }
            // Once per opening of the screen, as t:connect sends it on the bolus tab's tap.
            Task { await model.bolusScreenOpened() }
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
                    // With carbs off the calculator still corrects from the glucose; its food entry is units.
                    Text(flow.carbsOff ? "Calculator" : "Carbs").tag(BolusEntryMode.carbs)
                    Text("Units").tag(BolusEntryMode.units)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .onChange(of: flow.mode) { _, _ in flow.entryEdited() }
            }
            if flow.mode == .carbs {
                Section {
                    // Each entry row the same way: its name, then the value with its unit right after it, then
                    // the stepper.
                    // With carbs off on the pump the field takes the food insulin in units, as Tandem's app
                    // relabels it.
                    let insulin = flow.carbsOff
                    HStack(spacing: 6) {
                        Text(insulin ? "Insulin" : "Carbs")
                        Spacer(minLength: 8)
                        TextField("0", text: $flow.carbsText).keyboardType(insulin ? .decimalPad : .numberPad)
                            .multilineTextAlignment(.trailing).font(.title3.weight(.semibold))
                            .frame(maxWidth: 70).focused($focus, equals: .carbs)
                            .accessibilityLabel(insulin ? "Food insulin, units" : "Carbs, grams")
                        Text(insulin ? "U" : "g").foregroundStyle(.secondary)
                        Stepper(
                            "", value: carbsStep(flow), in: 0...(insulin ? 100 : 999),
                            step: insulin ? model.settings.bolusIncrement : Double(model.settings.carbIncrement)
                        )
                        .labelsHidden().accessibilityLabel(insulin ? "Food insulin" : "Carbs").padding(.leading, 6)
                    }
                    if insulin {
                        Text("Carbs are off on the pump: enter food insulin.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    // The CGM caption on its own line, the row's full width, so it fits with its unit.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Blood glucose")
                            Spacer(minLength: 8)
                            TextField("Blood glucose", text: $flow.glucoseText, prompt: placeholder(flow))
                                .keyboardType(.numberPad).font(.title3.weight(.semibold))
                                // The CGM value the dose uses, in plain text while nothing is typed (a
                                // placeholder is always grey); a grey hint again while typing.
                                .overlay(alignment: .trailing) {
                                    if let shown = cgmValueShown(flow) {
                                        Text(shown).font(.title3.weight(.semibold)).allowsHitTesting(false)
                                    }
                                }
                                .multilineTextAlignment(.trailing).focused($focus, equals: .glucose)
                                .accessibilityLabel("Blood glucose, mg/dL")
                                .frame(maxWidth: 110)
                            Text("mg/dL").foregroundStyle(.secondary)
                        }
                        cgmLine(flow).font(.subheadline)
                    }
                }
                // The user's own edits: the choice clears without an alert.
                .onChange(of: flow.carbsText) { _, _ in flow.carbsEdited() }
                .onChange(of: flow.glucoseText) { _, _ in flow.entryEdited() }
                recommendation(flow)
            }
            Section {
                HStack(spacing: 6) {
                    Text("Dose")
                    Spacer(minLength: 8)
                    // A dash while a card is still to be chosen: the line above the cards says to choose.
                    TextField(
                        flow.unavailableReason == BolusFlow.chooseText ? "–" : "0",
                        text: Binding(get: { flow.unitsText }, set: { flow.unitsTyped($0) })
                    )
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.title3.weight(.semibold))
                    .frame(maxWidth: 70).focused($focus, equals: .units).accessibilityLabel("Bolus, units")
                    Text("U").foregroundStyle(.secondary)
                    Stepper("", value: unitsStep(flow), in: 0...100, step: model.settings.bolusIncrement)
                        .labelsHidden().accessibilityLabel("Bolus units").padding(.leading, 6)
                }
                if flow.mode == .units { cgmLine(flow).font(.caption) }
                // Edited by hand in carbs mode: say so, and offer the way back to what the calculator gives.
                if flow.mode == .carbs, flow.unitsEdited, flow.recommendation.displaysNumericDose {
                    HStack {
                        Text("Your own dose").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button(flow.correctionQuestion != nil ? "Use the choices above" : "Use the suggestion") {
                            flow.useCalculatorDose()
                        }
                        .font(.footnote)
                    }
                }
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
        .listSectionSpacing(.compact)
        .contentMargins(.top, 8, for: .scrollContent)
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
        // The units follow a new reading or IOB as they follow typing, so the dose field never shows an
        // older number than the suggestion above it.
        .onChange(of: flow.basis) { _, _ in flow.entryChanged() }
        // The composer's questions, and a dose that changed under the user (said prominently, with a tap of
        // the phone, so it never looks like the screen glitched or the dose went), in a card of our own: a
        // system alert's glass is too see-through to read over the screen.
        .overlay {
            if let d = dialog(flow) { dialogCard(flow, d) }
        }
    }

    @ViewBuilder private func dialogCard(_ flow: BolusFlow, _ d: Dialog) -> some View {
        let content: (title: Text, message: String, warning: String?, buttons: [DialogButton]) =
            switch d {
            case .prompt(let prompt):
                (
                    Text(flow.text(for: prompt).title), flow.text(for: prompt).message, nil,
                    flow.text(for: prompt).choices.enumerated().map { index, choice in
                        DialogButton(label: choice.1, prominent: index == 0) { flow.choose(choice.0) }
                    } + [DialogButton(label: "Cancel", prominent: false) { flow.cancel() }]
                )
            case .change(let change):
                (
                    changeTitle(flow, change), flow.text(for: change).message, flow.text(for: change).warning,
                    [DialogButton(label: flow.text(for: change).button, prominent: true) { flow.acknowledgeChange() }]
                )
            }
        ZStack {
            // Dims the screen and takes its taps: only the card's buttons answer.
            Color.black.opacity(0.35).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 14) {
                content.title.font(.headline).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.8)
                if !content.message.isEmpty || content.warning != nil {
                    VStack(spacing: 4) {
                        if !content.message.isEmpty {
                            Text(content.message).foregroundStyle(.secondary)
                        }
                        if let warning = content.warning {
                            Text(warning).foregroundStyle(.orange).fontWeight(.semibold)
                        }
                    }
                    .font(.subheadline).multilineTextAlignment(.center)
                }
                VStack(spacing: 8) {
                    ForEach(Array(content.buttons.enumerated()), id: \.offset) { _, button in
                        if button.prominent {
                            Button(action: button.action) { Text(button.label).frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(AppTheme.insulin).controlSize(.large)
                        } else {
                            Button(action: button.action) { Text(button.label).frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 340)
            // White in light, raised grey in dark, so the card stands off the dimmed screen in both.
            .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 24))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity)
    }

    private struct DialogButton {
        let label: String
        let prominent: Bool
        let action: () -> Void
    }

    /// A change's title with the BG coloured as on the watch: the old reading grey, the new one in its
    /// range's colour.
    private func changeTitle(_ flow: BolusFlow, _ change: BolusFlow.CorrectionChange) -> Text {
        let unit = model.settings.glucoseUnit
        func went(_ from: Int, _ to: Int) -> Text {
            let old = Text("\(unit.format(mgdl: from))\u{00A0}mg/dL").foregroundStyle(.secondary)
            let new = Text("\(unit.format(mgdl: to))\u{00A0}mg/dL").foregroundStyle(AppTheme.glucoseColor(to))
            return Text("BG \(old) → \(new)")
        }
        switch change {
        case .glucose(let from, let to): return went(from, to)
        case .noQuestion(let from, let to?): return went(from, to)
        default: return Text(flow.text(for: change).title)
        }
    }

    private var takesCarbs: Bool { model.display.capabilities.supportsCarbEntry || model.pairing == nil }

    /// The glucose field's hint: the CGM value while typing (drawn plainly otherwise, by
    /// `cgmValueShown`), or a dash when there's no reading.
    private func placeholder(_ flow: BolusFlow) -> Text {
        guard let mgdl = flow.currentReading else { return Text("–") }
        return cgmValueShown(flow) != nil ? Text("") : Text(model.settings.glucoseUnit.format(mgdl: mgdl))
    }

    /// The CGM value drawn in the empty glucose field, or nil while the user is typing there.
    private func cgmValueShown(_ flow: BolusFlow) -> String? {
        guard flow.glucoseText.isEmpty, focus != .glucose, let mgdl = flow.currentReading else { return nil }
        return model.settings.glucoseUnit.format(mgdl: mgdl)
    }

    /// The CGM reading the dose may correct from, as a caption: under the glucose field in carbs mode.
    private func cgmLine(_ flow: BolusFlow) -> Text {
        let display = model.pumpDisplay(now: model.now)
        switch display.glucose {
        case .current(let mgdl, _, let at):
            // A reading the pump flags isn't used: the screen says why, and Confirm asks nothing.
            if let caution = model.screenGlucoseCaution {
                if let line = BolusFlow.cautionLine(caution, carbsOff: flow.carbsOff) {
                    return Text(line).foregroundStyle(.orange)
                }
                return Text("CGM \(display.unit.format(mgdl: mgdl)) mg/dL · checking the CGM's state")
                    .foregroundStyle(.secondary)
            }
            return Text("CGM \(display.unit.format(mgdl: mgdl)) mg/dL · \(display.age(at))").foregroundStyle(.secondary)
        case .stale(let mgdl, _, let at):
            // Too old to include, the dose is carbs only with no question; otherwise Confirm asks.
            let use = model.staleReadingIncludable ? "not used" : BolusFlow.noCorrection(flow.carbsOff)
            return Text("CGM \(display.unit.format(mgdl: mgdl)) mg/dL from \(display.age(at)): \(use)")
                .foregroundStyle(.orange)
        case .hidden, .none:
            return Text("No CGM reading: \(BolusFlow.noCorrection(flow.carbsOff))").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func recommendation(_ flow: BolusFlow) -> some View {
        let r = flow.recommendation
        Section {
            if !r.glucoseIsValid {
                Label(
                    "That glucose is outside 20–600 mg/dL. Re-check it before dosing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(AppTheme.low)
            }
            if let q = flow.correctionQuestion {
                correctionQuestion(flow, q)
            } else if r.displaysNumericDose {
                LabeledContent("Suggested dose", value: formatUnits(r.units)).fontWeight(.semibold)
            }
            if r.displaysNumericDose {
                if let message = r.message {
                    Label(message.text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if model.settings.showBolusReasoning, let c = r.calculation {
                    DisclosureGroup("Show the calculation", isExpanded: $showReasoning) {
                        LabeledContent(flow.carbsOff ? "Food" : "Carbs", value: formatUnits(c.fromCarbs))
                        LabeledContent("Correction", value: formatUnits(c.fromBG))
                        LabeledContent("Active insulin", value: "−" + formatUnits(c.fromIOB))
                        if !r.inputs.isVerified {
                            Text("faBolus reads the pump's settings and active insulin again when you confirm.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if flow.foodNeedsReentry {
                Label(
                    DoseRefusal.carbEntryChanged(carbsOff: flow.carbsOff).userMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout).foregroundStyle(.orange)
            } else if r.settingsUnusable {
                Label(
                    "The pump's correction factor or target can't be used, so no dose is calculated. Check them "
                        + "on the pump.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout).foregroundStyle(.orange)
            } else {
                Label("Waiting for the pump's bolus settings and active insulin…", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Add a correction? / Reduce the bolus?, with a card for each whole dose. Asked here, before Confirm,
    /// as on the watch; the card chosen is the dose.
    @ViewBuilder private func correctionQuestion(_ flow: BolusFlow, _ q: BolusFlow.CorrectionQuestion) -> some View {
        let unit = model.settings.glucoseUnit
        let bg = Text("\(unit.format(mgdl: q.mgdl)) mg/dL").foregroundStyle(AppTheme.glucoseColor(q.mgdl)).bold()
        // One row, so the spacing between the question, its cards and the note under them is ours, not the
        // list's row padding.
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(q.above ? "Add a correction?" : "Reduce the bolus?").font(.headline)
                Text("BG \(bg) · \(q.above ? "above" : "below") target \(unit.format(mgdl: q.targetMgdl)) mg/dL")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                correctionCard(flow, q, apply: true)
                correctionCard(flow, q, apply: false)
            }
            switch flow.correctionChange {
            case .glucose(let from, let to):
                Label(
                    "\(to > from ? "Up" : "Down") from \(unit.format(mgdl: from)) mg/dL. Choose again.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
            case .doses:
                Label("Doses updated. Choose again.", systemImage: "arrow.triangle.2.circlepath").font(.footnote)
            case .noQuestion, nil:
                if flow.correction == nil, !flow.unitsEdited {
                    Text("Each is the whole dose. Choose one.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func correctionCard(_ flow: BolusFlow, _ q: BolusFlow.CorrectionQuestion, apply: Bool) -> some View {
        let chosen = flow.correction?.apply == apply
        let label =
            apply
            ? (q.above ? "Corrected" : "Reduced")
            : (q.above ? BolusFlow.noCorrectionTitle(flow.carbsOff) : "Not reduced")
        let units = apply ? q.applyUnits : q.declineUnits
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            focus = nil
            flow.chooseCorrection(apply: apply)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label).font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? AppTheme.insulin : Color.secondary)
                }
                Text(formatUnits(units)).font(.title2.weight(.semibold)).monospacedDigit()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(chosen ? AppTheme.insulin.opacity(0.15) : Color(.tertiarySystemFill)))
            .overlay(shape.strokeBorder(chosen ? AppTheme.insulin : Color.clear, lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(formatUnits(units)) in all")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func carbsStep(_ flow: BolusFlow) -> Binding<Double> {
        Binding(
            // An entry of the other kind (typed before carbs were turned on or off) is no start for the new
            // one: stepping from it would read grams as units.
            get: { flow.foodNeedsReentry ? 0 : flow.carbs ?? 0 },
            set: {
                flow.carbsText = flow.carbsOff ? String(format: "%.2f", max(0, $0)) : String(Int($0))
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

    private enum Dialog: Equatable {
        case prompt(PhoneDosePrompt)
        case change(BolusFlow.CorrectionChange)
    }

    /// A change the user hasn't seen goes first: a prompt from the composer waits behind it. Each is answered
    /// only by its own buttons.
    private func dialog(_ flow: BolusFlow) -> Dialog? {
        // Not over the review: Deliver reads the pump again there and handles a change itself.
        if flow.phase == .editing, let change = flow.changeAlert { return .change(change) }
        if case .prompt(let p) = flow.phase { return .prompt(p) }
        return nil
    }

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
            VStack(spacing: 16) {
                Text(formatUnits(dose.units)).font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                // What the dose is for, as rows, once: carbs, the correction (or none), and the IOB counted.
                if !details.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(details.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider() }
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label)
                                    row.detail.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(row.units ?? "").monospacedDigit()
                            }
                            .font(.subheadline)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle.fill").font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                // The sheet closes when the flow leaves the review; dismissing here first would read as a cancel.
                Button {
                    onDeliver()
                } label: {
                    Text("Deliver \(formatUnits(dose.units))").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.insulin).controlSize(.large)
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Deliver bolus?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    /// A row of the split: what it is, a detail, and its share of the dose, the shares adding up to the
    /// dose (as Tandem's confirm screen shows food and correction). No shares for a dose the user entered.
    private struct Detail {
        let label: String
        let detail: Text
        let units: String?
    }

    private var details: [Detail] {
        var rows: [Detail] = []
        let carbs = dose.request.carbsGrams ?? 0
        let food = dose.calculatorFoodUnits
        // With carbs off, the food part is the insulin entered for it.
        let foodInsulin = dose.request.foodInsulinUnits ?? 0
        let hasFood = carbs > 0 || foodInsulin > 0
        if carbs > 0 {
            rows.append(
                Detail(label: "Food", detail: Text("\(Int(carbs)) g carbs"), units: food.map { formatUnits($0) }))
        } else if foodInsulin > 0 {
            rows.append(
                Detail(label: "Food", detail: Text("insulin entered, carbs off"), units: food.map { formatUnits($0) }))
        }
        let iob = dose.calculatorIOBUnits ?? 0
        if let bg = dose.correctionGlucoseMgdl {
            let reading = Text("\(bg) mg/dL").foregroundStyle(AppTheme.glucoseColor(bg)).bold()
            // The rest of the dose: what correcting from the glucose added, less the active insulin, or what a
            // low or below-target glucose took off.
            let rest = food.map { dose.units - $0 }
            // Under half a hundredth is none: no sign on it.
            let reduced = (rest ?? 0) < -0.005
            // The IOB is in this row's share: taken off a correction, part of a reduction.
            let iobPart = iob > 0 ? ", \(reduced ? "including" : "less") \(formatUnits(iob)) active insulin" : ""
            rows.append(
                Detail(
                    label: reduced ? "Reduction" : "Correction", detail: Text("for \(reading)\(iobPart)"),
                    units: rest.map { abs($0) < 0.005 ? formatUnits(0) : ($0 < 0 ? "−" : "+") + formatUnits(abs($0)) }))
        } else if hasFood {
            rows.append(Detail(label: "Correction", detail: Text("None"), units: nil))
        }
        if hasFood, food == nil {
            rows.append(Detail(label: "Your own dose", detail: Text("not the calculator's"), units: nil))
        }
        return rows
    }
}
