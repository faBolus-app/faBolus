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
    // SG3a (Insulin Stacking Guard, task #93): escalating friction state at the standard confirm seam.
    // Neither extra step ever changes `units` — both gate the SAME dose through to the unchanged
    // `attemptDeliver` path (see `handleStandardConfirm`).
    @State private var sgConfirmExtra = false
    @State private var sgReenter = false
    @State private var sgReenterText = ""
    @State private var sgReenterMismatch = false
    @State private var sgOriginalUnits: Double = 0
    // FLAG-4 (§1.5, REQ-D16-flags): the one-time DosingSafetyKit→SG advisory-behavior notice, shown once
    // at the first bolus-screen appearance (`.onAppear` below).
    @State private var showStackingGuardNotice = false
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
        let id = UUID()
        let kind: CalcInputGate.Kind   // pure, unit-tested gate decision (faBolusCore)
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
    /// DIF-ux: the pump never reported its bolus settings this attempt (`BolusRecommendation.therapyUnavailable`),
    /// so no dose can be safely sized — drives a cancel-only "settings not read yet" notice (fail-closed),
    /// never a deliverable dose off a guessed carb ratio. Per-attempt; reset on recompute / mode switch.
    @State private var calcInputBlocked = false
    private enum Field { case carbs, bg, units }
    @FocusState private var focus: Field?
    /// N12: drives the size-gated `.fixedSize()` on the compact carbs/units fields — kept at normal text
    /// sizes (so the one-glyph field + big tap target stays), dropped at accessibility sizes where a
    /// fixed width would clip the digits.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        mode == .carbs && bgSource == .cgm && model.snapshot.isGlucoseStale && (settings.glucoseDisplayUnit.parse(bg) ?? 0) > 0
    }

    /// Phase 04-01 (D-07/D-09) — the entry-parse boundary. `bg` is typed in whichever unit
    /// `settings.glucoseDisplayUnit` selects; every former bare integer-parse call site below now
    /// calls `settings.glucoseDisplayUnit.parse(bg)` directly, the ONLY conversion of that text to
    /// the canonical mg/dL `Int` that reaches `recommendBolus`/`BolusMath`/`RemoteCommand`. `nil`
    /// means "no BG entered" — callers MUST NOT coerce it to `0` (a fabricated glucose reading
    /// silently entering correction math is the exact hazard this phase exists to prevent).

    /// The bg field's keyboard type: `.decimalPad` in mmol mode (a decimal point is required),
    /// `.numberPad` in mgdl mode (unchanged behavior). `static`/pure so it's directly unit-testable
    /// without instantiating the view (`BolusEntryUnitParseTests`).
    static func bgKeyboardType(for unit: GlucoseUnit) -> UIKeyboardType {
        unit == .mmol ? .decimalPad : .numberPad
    }
    /// The bg field's placeholder, naming the active unit.
    static func bgPlaceholder(for unit: GlucoseUnit) -> String {
        unit == .mmol ? "mmol/L" : "mg/dL"
    }
    /// The bg field's accessibility label, naming the active unit.
    static func bgAccessibilityLabel(for unit: GlucoseUnit) -> String {
        unit == .mmol ? "Blood glucose, mmol/L" : "Blood glucose, mg/dL"
    }

    /// Phase 04-02 (D-10): the two stale/CGM-changed reading messages — whole-phrase catalog
    /// VARIANTS selected by the active display unit, not a glued suffix. `mgdl` stays the canonical
    /// reading; only its formatted display value and the chosen catalog phrase change.
    private func staleReadingMessage(mgdl: Int, carbsOnlyLabel: String) -> String {
        let value = settings.glucoseDisplayUnit.format(mgdl: mgdl)
        if settings.glucoseDisplayUnit == .mmol {
            return String(format: String(localized: "Your CGM reading (%@ mmol/L) is stale and was left out of this dose. Include it in the correction, deliver carbs only (%@), or cancel."), value, carbsOnlyLabel)
        } else {
            return String(format: String(localized: "Your CGM reading (%@ mg/dL) is stale and was left out of this dose. Include it in the correction, deliver carbs only (%@), or cancel."), value, carbsOnlyLabel)
        }
    }
    private func cgmChangedMessage(mgdl: Int, newLabel: String, oldLabel: String) -> String {
        let value = settings.glucoseDisplayUnit.format(mgdl: mgdl)
        if settings.glucoseDisplayUnit == .mmol {
            return String(format: String(localized: "Your CGM changed while this dose was on screen. The new reading (%@ mmol/L) suggests %@ instead of %@."), value, newLabel, oldLabel)
        } else {
            return String(format: String(localized: "Your CGM changed while this dose was on screen. The new reading (%@ mg/dL) suggests %@ instead of %@."), value, newLabel, oldLabel)
        }
    }

    private var carbs: Double { Double(carbsText) ?? 0 }
    private var units: Double { Double(unitsText) ?? 0 }
    /// Advisory (never blocks): the user has adjusted the dose away from the calculator's recommendation
    /// for a carb bolus, so the carbs recorded on the pump won't match the delivered units. Uses the same
    /// conservative 0.10 U limit as the remote divergence guard.
    private var carbOverrideWarning: String? {
        // §13 Rule-1 (A1): don't cite the calculator's number when it's sized off a hardcoded guess
        // (`!displaysNumericDose`) — the "suggested %.2f U" would trace to an uncited literal.
        guard mode == .carbs, carbs > 0, let rec = recommendation, rec.displaysNumericDose, rec.recommendedUnits > 0,
              abs(units - rec.recommendedUnits) > AppModel.remoteDivergenceLimitUnits else { return nil }
        return String(format: "Delivering %.2f U for %.0f g — the calculator suggested %.2f U. The carbs will still be recorded on the pump with this dose.",
                      units, carbs, rec.recommendedUnits)
    }
    /// O3 (ambient): the controller's "automatic correction is active" line, or nil. Pure faBolusCore
    /// disclosure derived from the pump's controller descriptor + runtime on/off — NEVER gates delivery.
    private var autoCorrectionAmbient: String? {
        AutoCorrectionDisclosure.ambientIndicator(descriptor: model.snapshot.controllerDescriptor,
                                                  controllerEnabled: model.snapshot.controlIQEnabled)
    }
    /// S1: the high/rising auto-correction lockout disclosure, or nil. Uses the pump's OWN trend arrow
    /// (mapped from the raw snapshot string) — never a computed rate (C8). NEVER gates delivery.
    private var autoCorrectionLockout: String? {
        AutoCorrectionDisclosure.lockoutMessage(descriptor: model.snapshot.controllerDescriptor,
                                                controllerEnabled: model.snapshot.controlIQEnabled,
                                                glucoseMgdl: model.snapshot.glucose,
                                                trend: GlucoseTrend(rawValue: model.snapshot.trend))
    }
    /// SG1: the calc-override disclosure, or nil. Pure `faBolusCore` disclosure — reads the pump's OWN
    /// op-115 target (never a hardcoded clinical constant) and NEVER gates, changes, or delays delivery;
    /// same "disclosure only" contract as `autoCorrectionAmbient`/`autoCorrectionLockout` above.
    private var sg1Disclosure: StackingGuard.Disclosure? {
        guard let rec = recommendation else { return nil }
        let disclosure = StackingGuard.calcOverride(enteredUnits: units, recommendedUnits: rec.recommendedUnits,
                                                     displaysNumericDose: rec.displaysNumericDose,
                                                     pumpIOBUnits: rec.iobUnits,
                                                     glucoseMgdl: model.snapshot.glucose,
                                                     targetMgdl: model.snapshot.targetBg)
        return disclosure.friction == .none ? nil : disclosure
    }
    /// SG2: the max-bolus proximity disclosure, or nil. Pure `faBolusCore` disclosure anchored solely on the
    /// pump's own op-115 `maxBolusUnits` — never gates, changes, or delays delivery; same "disclosure only"
    /// contract as `sg1Disclosure` above. Renders beside the existing "Exceeds pump max" label (:320-323
    /// pattern), an additional pump-anchored disclosure, not a replacement for it.
    private var sg2Disclosure: StackingGuard.Disclosure? {
        let disclosure = StackingGuard.maxBolusProximity(enteredUnits: units, maxBolusUnits: model.snapshot.maxBolusUnits)
        return disclosure.friction == .none ? nil : disclosure
    }
    /// SG3a: the escalating-friction disclosure, or nil. Pure `faBolusCore` disclosure — reads the pump's
    /// OWN op-115 target/max (never a hardcoded clinical constant) and NEVER gates, changes, or delays
    /// delivery on its own; the escalated CONFIRM/RE-TYPE steps below are UI wiring layered on top of this
    /// same disclosure, never a new dose decision. Unlike `sg1Disclosure`/`sg2Disclosure`, this is NOT gated
    /// on `settings.stackingGuardFrictionEnabled` here — the message/band LINE always renders when SG3a
    /// fires (per `AppSettings.stackingGuardFrictionEnabled`'s doc comment: "SG3a's own .disclose line still
    /// render[s]" when the toggle is off); the toggle only caps which ESCALATED friction tier is actually
    /// applied at the confirm seam (`sg3aAppliedFriction` below).
    private var sg3aDisclosure: StackingGuard.Disclosure? {
        guard let rec = recommendation else { return nil }
        let disclosure = StackingGuard.escalation(enteredUnits: units, recommendedUnits: rec.recommendedUnits,
                                                   displaysNumericDose: rec.displaysNumericDose,
                                                   pumpIOBUnits: rec.iobUnits,
                                                   glucoseMgdl: model.snapshot.glucose,
                                                   targetMgdl: model.snapshot.targetBg,
                                                   maxBolusUnits: model.snapshot.maxBolusUnits)
        return disclosure.friction == .none ? nil : disclosure
    }
    /// The friction tier ACTUALLY applied at the confirm seam: when `stackingGuardFrictionEnabled` is off,
    /// any escalated tier (`.confirmExtra`/`.reenter`) is capped down to `.disclose` — the message/band line
    /// still shows (via `sg3aDisclosure` above), but the extra-confirm / re-type friction no longer gates
    /// delivery. When the toggle is on, the tier is applied as `StackingGuard.escalation` computed it.
    private var sg3aAppliedFriction: StackingGuard.Friction {
        guard let f = sg3aDisclosure?.friction, f != .none else { return .none }
        return settings.stackingGuardFrictionEnabled ? f : .disclose
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
        // SG3a: compose the escalating-friction message into the STANDARD confirm dialog too — the
        // `.disclose` tier's "no extra tap" contract (the message shows here; nothing further gates it).
        // For `.confirmExtra`/`.reenter` this still shows as context BEFORE the extra step (added below at
        // the confirm seam), never a replacement for it.
        if let sg3a = sg3aDisclosure, let message = sg3a.message { parts.append(message) }
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
    /// §13 Rule-1 (A1) DRAFT copy, §13-pending — shown in the "Recommended" card when the pump's bolus
    /// settings haven't been read yet, in place of a numeric dose sized off a hardcoded guess. Kept as a
    /// single constant so the wording (which must pass §13 clinical review before any experimental
    /// distribution) has one home; no control flow or dose logic depends on the string.
    static let awaitingPumpSettingsCopy = "Waiting to read this pump's bolus settings (carb ratio, correction factor, target). No dose can be recommended until they're read — check your pump connection."

    /// FLAG-4 (§1.5, REQ-D16-flags) DRAFT copy, §13-pending — the DosingSafetyKit→SG advisory-behavior
    /// change notice, shown once at the first bolus-screen appearance. Plain-language, non-alarming —
    /// mirrors the `TherapyEditAck` tone. Kept as one string constant (same idiom as
    /// `awaitingPumpSettingsCopy` above) so the wording has one home; no control flow depends on it.
    static let stackingGuardNoticeCopy = "This version adds Insulin Stacking Guard: extra on-screen context, and for larger overrides an extra confirmation or a re-type step before an unusually large dose delivers. It's advisory only — it never blocks, resizes, or changes the amount you choose to deliver."

    /// SG3a `.reenter` exact-match rule: a re-typed value must equal `original` (within floating-point
    /// tolerance) to proceed — ANY other value is rejected/re-prompted, never delivered as a new (resized)
    /// amount (T-01-08). `internal` (not `private`) so `StackingGuardDeliverInvariantTests` (`@testable
    /// import faBolus`) can prove the MUST-NOT-BLOCK invariant's re-type counterpart directly: a mismatched
    /// re-type never satisfies this check.
    static func reenterMatches(retyped: Double, original: Double) -> Bool {
        abs(retyped - original) < 0.005
    }

    /// Compact units string: 1.00 → "1", 1.50 → "1.5", 0.05 → "0.05".
    private static func trimUnits(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var body: some View {
        withSG3aFriction(
            Group {
                if embedded { content } else { NavigationStack { content } }
            }
        )
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
                                .keyboardType(.numberPad)
                                .compactFixedSize(dynamicTypeSize.isAccessibilitySize)
                                .font(.title3.weight(.semibold)).focused($focus, equals: .carbs)
                                .accessibilityLabel("Carbs, grams")
                            Text("g carbs").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { focus = .carbs }
                        Stepper("", value: carbsStep, in: 0...300, step: settings.carbIncrement).labelsHidden()
                            .accessibilityLabel("Carbs")
                    }
                    LabeledContent("Blood glucose") {
                        TextField(Self.bgPlaceholder(for: settings.glucoseDisplayUnit), text: bgField)
                            .keyboardType(Self.bgKeyboardType(for: settings.glucoseDisplayUnit))
                            .multilineTextAlignment(.trailing).focused($focus, equals: .bg)
                            .accessibilityLabel(Self.bgAccessibilityLabel(for: settings.glucoseDisplayUnit))
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
                        if rec.displaysNumericDose {
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
                        } else {
                            // §13 Rule-1 (A1): the pump's bolus settings (carb ratio / correction factor /
                            // target) have NOT been read this session, so any recommendation would be sized off
                            // a hardcoded CR 10 / ISF 40 / target 110 guess — an uncited literal. Suppress the
                            // numeric dose entirely (`rec.displaysNumericDose == false`) and prompt to wait for
                            // the read. Delivery is already blocked (CalcInputGate → .blockNoTherapy). DRAFT
                            // copy, §13-pending.
                            Label(BolusEntryView.awaitingPumpSettingsCopy, systemImage: "hourglass")
                                .font(.callout).foregroundStyle(.secondary)
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
                        .accessibilityLabel("Cancel bolus")
                    }
                } else {
                    HStack(spacing: 6) {
                        // Enlarged tap target (see the carbs field) — visuals unchanged.
                        HStack(spacing: 6) {
                            TextField("0", text: $unitsText)
                                .keyboardType(.decimalPad)
                                .compactFixedSize(dynamicTypeSize.isAccessibilitySize)
                                .font(.title3.weight(.semibold)).focused($focus, equals: .units)
                                .foregroundStyle(overMax ? AppTheme.low : .primary)
                                .accessibilityLabel("Bolus, units")
                                .accessibilityValue(unitsText.isEmpty ? "0 units" : "\(unitsText) units")
                            Text("U").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { focus = .units }
                        Stepper("", value: unitsStep, in: 0...max(maxUnits, 0.01), step: settings.bolusIncrement).labelsHidden()
                            .accessibilityLabel("Bolus units")
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
                    // SG2 (Insulin Stacking Guard, task #93): max-bolus proximity DISCLOSURE only — same
                    // "never inside a gate" contract as the SG1 line below. Anchored solely on the pump's
                    // own op-115 maxBolusUnits (never a hardcoded cap); additional to the overMax label
                    // above, not a replacement.
                    if let sg2 = sg2Disclosure, let message = sg2.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
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
                    // Dose overridden away from the carb recommendation (advisory; carbs still logged).
                    if let w = carbOverrideWarning {
                        Label(w, systemImage: "pencil.and.outline")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    // O3 (ambient) + S1 (lockout) auto-correction DISCLOSURE. Pure faBolusCore strings,
                    // rendered unconditionally when applicable (Simple-mode floor, not user-disableable) —
                    // NEVER inside a gate: they never block, change, or delay the dose. O3 is neutral
                    // context; S1 is a mild caution shown only at high/rising glucose.
                    if let ambient = autoCorrectionAmbient {
                        Label(ambient, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let lockout = autoCorrectionLockout {
                        Label(lockout, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    // SG1 (Insulin Stacking Guard, task #93): calc-override DISCLOSURE only — same
                    // "never inside a gate" contract as the auto-correction lines above. NEVER touches
                    // the Deliver button below.
                    if let sg1 = sg1Disclosure, let message = sg1.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    // SG3a (Insulin Stacking Guard, task #93): escalating-friction DISCLOSURE line — same
                    // "band" render as SG1/SG2 above. The message always shows when SG3a fires (even with
                    // `stackingGuardFrictionEnabled` off — see `sg3aDisclosure`'s doc comment); the
                    // ESCALATED confirm/re-type friction this can additionally require is wired at the
                    // confirm seam below (`handleStandardConfirm`), never here. `.disclose`-tier reuses SG1's
                    // exact message (see `StackingGuard.escalation`), so this line is suppressed when it
                    // would be a verbatim duplicate of the SG1 label already shown above — only a
                    // confirmExtra/reenter-tier message (which differs) renders as an additional line.
                    if let sg3a = sg3aDisclosure, let message = sg3a.message, message != sg1Disclosure?.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button { confirming = true } label: {
                        HStack { Spacer(); Text(preparingDeliver ? "Checking CGM…" : "Bolus \(String(format: "%.2f U", units))"); Spacer() }
                    }
                    .buttonStyle(.borderedProminent).tint(AppTheme.insulin)
                    .disabled(!model.bolusGate(amount: units, minimum: 0.05).canBolus || preparingDeliver)
                    // N12: the button reads its full dose ("Deliver 2.50 units"), not just "Bolus".
                    .accessibilityLabel(preparingDeliver ? "Checking CGM" : "Deliver \(String(format: "%.2f", units)) units")
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
                    .accessibilityLabel("Deliver extended \(String(format: "%.2f", units)) units")
                }
            }
        }
        .navigationTitle("Bolus")
        .navigationBarTitleDisplayMode(.inline)
        // N12 (Dynamic Type): scale up to the largest accessibility text size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
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
            // FLAG-4 (§1.5, REQ-D16-flags): first-use disclosure that this version adds Insulin Stacking
            // Guard's advisory friction. Shown once (persisted), non-blocking — the screen stays usable
            // regardless, same idiom as `TherapyEditAck` (PumpWizardViews.swift).
            if !AppSettings.shared.hasAcknowledgedStackingGuardNotice { showStackingGuardNotice = true }
        }
        // Recompute the recommendation live as carbs / BG change — no "Calculate" button needed.
        .onChange(of: carbsText) { _, _ in if mode == .carbs { Task { await calculate() } } }
        .onChange(of: bg) { _, _ in if mode == .carbs { Task { await calculate() } } }
        .onChange(of: mode) { _, newMode in
            // Switching modes starts a FRESH entry. Clear any carry-over first: a carbs-calculator dose can
            // be from an UNVERIFIED recommendation (`inputsVerified == false`, e.g. sized off the hardcoded
            // assumed CR/ISF/target before op-115 lands), and the deliver-time warned-override gate is
            // carbs-mode-only — so a stale carb dose left in the Units field would deliver in Units mode with
            // NO acknowledgement. Clearing `unitsText`/`recommendation` here makes Units mode start empty
            // (Deliver stays disabled until the user dials a number), closing that carry-over. Carbs mode
            // then recomputes from the current carbs/BG.
            recommendation = nil
            unitsText = ""
            calcInputPrompt = nil
            acceptedOverride = nil
            calcInputBlocked = false
            if newMode == .carbs { Task { await calculate() } }
        }
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
            Button("Deliver \(String(format: "%.2f U", units))", role: .destructive) { handleStandardConfirm() }
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
                            let ext = u.extended; let carbsOnlyUnits = u.newUnits; cgmUpdate = nil
                            // Defense-in-depth (Addendum B cap): the option is only ever OFFERED for a
                            // within-window reading, but re-verify at TAP time through the SAME single bound
                            // (`StaleBolusPrompt.mayOfferInclude` → `withinIncludableStaleness`). If the reading
                            // aged past `maxIncludableStaleness` since the dialog opened, fail closed to the
                            // carbs-only dose rather than dosing an insulin-INCREASING correction off a
                            // now-too-old reading. Never over-delivers vs the choice the user was offered.
                            if StaleBolusPrompt.mayOfferInclude(glucoseMgdl: sbg, glucoseDate: model.snapshot.glucoseDate) {
                                Task { await deliverFrozen(freeze(units: su, bg: sbg, extended: ext)) }
                            } else {
                                Task { await deliverFrozen(freeze(units: carbsOnlyUnits, bg: nil, extended: ext)) }
                            }
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
                        let ext = u.extended; let uu = u.oldUnits; let bgv = settings.glucoseDisplayUnit.parse(bg); cgmUpdate = nil
                        Task { await deliverFrozen(freeze(units: uu, bg: bgv, extended: ext)) }
                    }
                    Button("Cancel", role: .cancel) { cgmUpdate = nil }
                }
            }
        } message: {
            if let u = cgmUpdate {
                if u.newBG == -1 {
                    if let sbg = u.staleBG {
                        Text(staleReadingMessage(mgdl: sbg, carbsOnlyLabel: String(format: "%.2f U", u.newUnits)))
                    } else {
                        Text("No fresh CGM reading is available, so the correction can't be applied. Deliver the carbs-only dose (\(String(format: "%.2f U", u.newUnits))) or cancel.")
                    }
                } else {
                    Text(cgmChangedMessage(mgdl: u.newBG, newLabel: String(format: "%.2f U", u.newUnits), oldLabel: String(format: "%.2f U", u.oldUnits)))
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
        // DIF-ux: the pump never reported its bolus settings this attempt, so no dose can be safely sized.
        // Cancel-only (fail-closed) — NEVER a deliverable dose off a guessed carb ratio, and no false
        // "last-known" label. The user retries once the pump reports its settings.
        .alert("Pump settings not read yet", isPresented: $calcInputBlocked) {
            Button("OK", role: .cancel) { calcInputBlocked = false }   // sends NOTHING
        } message: {
            Text("faBolus hasn't read this pump's bolus settings (carb ratio / correction factor / target) yet, so it can't size a dose. Wait a moment for the pump to connect, then try again.")
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

    /// SG3a's escalated-friction dialogs (`.confirmExtra`/`.reenter`) + the FLAG-4 one-time notice, applied
    /// as a SEPARATE modifier group (not inline in `content`'s chain above). Splitting these out keeps each
    /// chained-modifier expression small enough for the type-checker — `content`'s chain was already long
    /// before this plan, and appending these three `.confirmationDialog`/`.alert` modifiers directly onto it
    /// pushed a single SwiftUI modifier-chain expression past what the compiler can type-check in
    /// reasonable time (no behavior difference: `.alert`/`.confirmationDialog` attach presentation state via
    /// the view hierarchy regardless of which ancestor they're applied to).
    @ViewBuilder
    private func withSG3aFriction<V: View>(_ view: V) -> some View {
        view
            // SG3a `.confirmExtra`: one ADDITIONAL confirmation step beyond the standard confirm dialog —
            // routed here by `handleStandardConfirm` only when `sg3aAppliedFriction == .confirmExtra`. Gates
            // the SAME dose (`sgOriginalUnits`, captured at the moment the standard dialog's Deliver was
            // tapped) — Cancel sends NOTHING; Deliver proceeds to the unchanged `attemptDeliver` path with
            // `units` unchanged (never resized by this step).
            .confirmationDialog("Confirm again — deliver \(String(format: "%.2f U", sgOriginalUnits))?",
                                isPresented: $sgConfirmExtra, titleVisibility: .visible) {
                Button("Deliver \(String(format: "%.2f U", sgOriginalUnits))", role: .destructive) {
                    Task { await attemptDeliver(extended: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This dose is well above what the pump's calculator suggested. Confirm once more before delivering — the amount will not change.")
            }
            // SG3a `.reenter`: the user must re-type the dose to proceed. A re-typed value that does not
            // EXACTLY match `sgOriginalUnits` (captured at the moment the standard dialog's Deliver was
            // tapped) is REJECTED and re-prompted — it NEVER becomes a new (resized) delivered amount; only
            // an exact match proceeds to the unchanged `attemptDeliver` path. SwiftUI dismisses an `.alert`
            // on every button tap, so a mismatch re-presents this SAME alert on the next runloop turn.
            .alert("Re-enter your dose to confirm", isPresented: $sgReenter) {
                TextField("Units", text: $sgReenterText).keyboardType(.decimalPad)
                Button("Confirm", role: .destructive) {
                    let candidate = sgReenterText
                    sgReenterText = ""
                    if let retyped = Double(candidate), Self.reenterMatches(retyped: retyped, original: sgOriginalUnits) {
                        sgReenterMismatch = false
                        Task { await attemptDeliver(extended: false) }
                    } else {
                        sgReenterMismatch = true
                        DispatchQueue.main.async { sgReenter = true }
                    }
                }
                Button("Cancel", role: .cancel) { sgReenterMismatch = false }
            } message: {
                Text(sgReenterMessage)
            }
            // FLAG-4 (§1.5, REQ-D16-flags): the one-time DosingSafetyKit→SG advisory-behavior notice, shown
            // once at the first bolus-screen appearance (`.onAppear`). Non-blocking — never gates a dose; it
            // only records that the disclosure was shown and accepted, same idiom as `TherapyEditAck`.
            .alert("New: Insulin Stacking Guard", isPresented: $showStackingGuardNotice) {
                Button("I understand") { AppSettings.shared.acknowledgeStackingGuardNotice() }
            } message: {
                Text(Self.stackingGuardNoticeCopy)
            }
    }

    /// SG3a: route the tap from the STANDARD confirm dialog through the friction tier ACTUALLY applied
    /// (`sg3aAppliedFriction` — capped to `.disclose` when `stackingGuardFrictionEnabled` is off). `units`
    /// is captured into `sgOriginalUnits` at THIS moment (audit C-04 "freeze once" idiom) so a field edit
    /// under a later dialog can't silently substitute a different dose into the re-type check. Neither
    /// `.confirmExtra` nor `.reenter` ever changes `units` itself — both gate the SAME dose through to the
    /// unchanged `attemptDeliver` path.
    private func handleStandardConfirm() {
        sgOriginalUnits = units
        switch sg3aAppliedFriction {
        case .reenter:
            sgReenterText = ""
            sgReenterMismatch = false
            sgReenter = true
        case .confirmExtra:
            sgConfirmExtra = true
        case .disclose, .none:
            Task { await attemptDeliver(extended: false) }
        }
    }

    /// The re-type alert's message, keyed on whether the PREVIOUS attempt mismatched — never implies the
    /// mismatched number was accepted or delivered.
    private var sgReenterMessage: String {
        sgReenterMismatch
            ? "That doesn't match \(String(format: "%.2f", sgOriginalUnits)) U — nothing was delivered. Re-enter \(String(format: "%.2f", sgOriginalUnits)) U exactly to confirm, or cancel."
            : "This dose is far above what the pump's calculator suggested. Re-enter \(String(format: "%.2f", sgOriginalUnits)) U exactly to confirm — the amount will not change."
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
        guard carbs > 0 || (settings.glucoseDisplayUnit.parse(bg) ?? 0) > 0 else { recommendation = nil; unitsText = ""; return }
        // Generation token (audit C-04): a newer edit supersedes this calc, so an out-of-order async
        // result can't overwrite the field with a stale dose.
        calcSeq &+= 1
        let seq = calcSeq
        calcInputPrompt = nil       // DIF-ux: a changed dose re-requires the per-attempt freshness override
        acceptedOverride = nil      // …and drops any override accepted for a prior compose
        calcInputBlocked = false    // …and clears any prior "settings not read" block
        let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: settings.glucoseDisplayUnit.parse(bg))
        guard seq == calcSeq else { return }
        recommendation = rec
        // §13 Rule-1 (A1): never pre-fill the units field with a dose sized off a hardcoded CR/ISF/target
        // guess (`!displaysNumericDose`) — that number traces to an uncited literal. The field stays empty;
        // delivery is blocked anyway (CalcInputGate → .blockNoTherapy) until the pump reports its settings.
        unitsText = (rec.displaysNumericDose && rec.recommendedUnits > 0) ? Self.trimUnits(rec.recommendedUnits) : ""
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
        // DIF-ux: the deliver-time gate is the PURE, unit-tested `CalcInputGate.decide` (faBolusCore) — no
        // gating logic lives inline here anymore. It fires ONLY in carbs mode, keys on `!inputsVerified`
        // BEFORE any staleness flag (so the unconfirmed-but-in-window case is caught → `.both`), and skips
        // once an override was accepted this attempt (re-entry). A Units-mode dose is the number the user
        // dialed — a carbs-calc dose can't reach here, it's cleared on the mode switch. `.prompt` shows the
        // WARNED two-way override; accepting sets `acceptedOverride` and RE-ENTERS this method, which runs
        // the full deliver-time machinery below (fresh-CGM refresh + divergence guard + Addendum-B stale-CGM
        // three-way) with the override threaded in. `cancel` sends nothing. Remotes never reach this — they
        // fail closed in `resolveRemoteDose`.
        if let rec = recommendation, calcInputPrompt == nil, !calcInputBlocked {
            switch CalcInputGate.decide(isCarbsMode: mode == .carbs, inputsVerified: rec.inputsVerified,
                                        iobStale: rec.iobStale, therapyStale: rec.therapyStale,
                                        therapyAvailable: !rec.therapyUnavailable,
                                        overrideAccepted: acceptedOverride != nil) {
            case .proceed:
                break   // fall through to the deliver machinery below
            case .blockNoTherapy:
                // The pump has NEVER reported its bolus settings this attempt, so any dose would be sized off
                // a hardcoded guess — no honest "last-known" to offer and a carb dose can't be sized without
                // a real carb ratio. Block with a cancel-only notice (fail-closed); the user retries once the
                // pump reports its settings (the next compose forces a fresh op-115 read).
                calcInputBlocked = true
                return
            case .prompt(let kind):
                // Precompute the override dose off last-known values + the on-screen BG so the button shows
                // the estimate (the divergence BASELINE). The ACTUAL delivered dose is the deliver-time
                // recompute below (CGM path: fresh-read + divergence guard) or the min(baseline, fresh) cap
                // (manual-BG path), so drift since compose is still caught.
                let pre = await model.recommendBolus(carbsGrams: carbs, bgMgdl: settings.glucoseDisplayUnit.parse(bg),
                                                     allowStaleIob: kind.allowStaleIob, allowStaleTherapy: kind.allowStaleTherapy)
                calcInputPrompt = CalcInputPrompt(kind: kind, extended: extended, overrideUnits: pre.recommendedUnits,
                                                  allowStaleIob: kind.allowStaleIob, allowStaleTherapy: kind.allowStaleTherapy,
                                                  iobUnits: rec.iobUnits, iobDate: rec.iobDate,
                                                  assumedProfile: rec.assumedProfile, therapyDate: rec.therapyParamsDate)
                return
            }
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
                await deliverFrozen(freeze(units: priorUnits, bg: settings.glucoseDisplayUnit.parse(bg), extended: extended))
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
            // Addendum B includable-age cap (iPhone fast-follow, mirrors the host `resolveRemoteDose` gate):
            // offer the "include the stale reading" option ONLY when the reading is within the includable
            // window `(staleAfter, maxIncludableStaleness]` — `StaleBolusPrompt.mayOfferInclude` routes through
            // the ONE bound `GlucoseFreshness.withinIncludableStaleness`. A reading present but OLDER than the
            // cap is too old to dose a correction from: fall through to the carbs-only / cancel branch below
            // (identical to "no includable reading") — never compute or offer a `withStale` correction off it.
            if let sg = model.snapshot.glucose,
               StaleBolusPrompt.mayOfferInclude(glucoseMgdl: sg, glucoseDate: model.snapshot.glucoseDate) {
                let withStale = await model.recommendBolus(carbsGrams: carbs, bgMgdl: sg,
                                                           allowStaleIob: ov?.allowStaleIob ?? false,
                                                           allowStaleTherapy: ov?.allowStaleTherapy ?? false)
                cgmUpdate = CGMUpdatePrompt(newBG: -1, newUnits: carbsOnly.recommendedUnits, oldUnits: priorUnits,
                                           extended: extended, staleBG: sg, staleUnits: withStale.recommendedUnits)
            } else {
                // No includable reading: none present, OR present but OLDER than the includable cap
                // (`maxIncludableStaleness`). Carbs-only / cancel only — no Include choice, no stale-basis dose.
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
            let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: settings.glucoseDisplayUnit.parse(bg),
                                                 allowStaleIob: ov.allowStaleIob, allowStaleTherapy: ov.allowStaleTherapy)
            let capped = CalcInputGate.overrideDeliverUnits(baseline: ov.baseline, freshRecompute: rec.recommendedUnits)
            await deliverFrozen(freeze(units: capped, bg: settings.glucoseDisplayUnit.parse(bg), extended: extended))
        } else {
            await deliverFrozen(freeze(units: units, bg: settings.glucoseDisplayUnit.parse(bg), extended: extended))
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

private extension View {
    /// N12: apply `.fixedSize()` (compact one-glyph field) at normal text sizes, but NOT at accessibility
    /// sizes — where a fixed width clips the digits. Presentation-only: the default-size layout is
    /// unchanged; only accessibility sizes let the field grow.
    @ViewBuilder func compactFixedSize(_ isAccessibility: Bool) -> some View {
        if isAccessibility { self } else { self.fixedSize() }
    }
}
