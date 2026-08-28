import SwiftUI
import UIKit
import faBolusCore
import faBolusDesign

/// Bolus entry (modern). Carbs (+ optional BG) → recommended dose, or a plain Units dial —
/// default mode and the ± increments come from Settings. Experimental; enforces the
/// max-units interlock and an explicit confirm. Works as a tab (`embedded`) or a sheet.
struct BolusEntryView: View {
    let model: AppModel
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    // Read live via @Environment (never cached in @State, so rotation/Split-View resize
    // re-triggers the cap correctly).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    // Success toast. Set only from the model's already-resolved outcome — this view never
    // computes a delivery result.
    @State private var successBanner: BolusSuccessBanner?
    @State private var showReasoning = false
    // Extended (combo) bolus
    @State private var extendedOn = false
    @State private var extendedDurationMin = 120
    @State private var extendedNowPercent = 50
    @State private var confirmingExtended = false
    // SG3a stacking-guard friction at the standard confirm seam. Extra steps never change `units`.
    @State private var sgConfirmExtra = false
    @State private var sgReenter = false
    @State private var sgReenterText = ""
    @State private var sgReenterMismatch = false
    @State private var sgOriginalUnits: Double = 0
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
    /// `newBG == -1` means no fresh CGM — drop the correction (carbs-only) rather than dose off a
    /// stale on-screen value (fail-closed). `extended` routes back to the matching delivery path.
    private struct CGMUpdatePrompt: Identifiable {
        let id = UUID(); let newBG: Int; let newUnits: Double; let oldUnits: Double; let extended: Bool
        // Stale (not merely missing): value + the dose it would produce, so the prompt can offer
        // "include the stale reading". nil ⇒ no reading at all (carbs-only / cancel only).
        var staleBG: Int? = nil
        var staleUnits: Double? = nil
    }
    /// Generation token: a newer edit supersedes this calc so an out-of-order async result can't
    /// overwrite the field with a stale dose.
    @State private var calcSeq = 0
    /// Deliver-time prompt when recommendation inputs weren't confirmed fresh this compose.
    /// Carries the override dose (button label == delivered amount) and which override(s) apply.
    /// Per-attempt — reset on every `calculate()`, never sticky, never default-selected.
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
    /// Override accepted this attempt. Re-entering `attemptDeliver` skips the warning gate but still
    /// runs fresh-CGM refresh, the 0.10 U divergence guard, and the stale-CGM three-way — so a stale
    /// IOB/therapy override never bypasses the stale-CGM warning and never doses a correction off an
    /// unrefreshed on-screen glucose. `baseline` is the button's shown dose (compose-time BG), used
    /// as the divergence point so the guard catches a real CGM move, not the expected correction.
    /// Consumed at the top of `attemptDeliver`. Remotes never reach this (`resolveRemoteDose` fail-closed).
    private struct AcceptedOverride { let allowStaleIob: Bool; let allowStaleTherapy: Bool; let baseline: Double }
    @State private var acceptedOverride: AcceptedOverride?
    /// Pump never reported bolus settings this attempt — cancel-only notice, never a dose off a
    /// guessed carb ratio (fail-closed). Reset on recompute / mode switch.
    @State private var calcInputBlocked = false
    /// Cancel-only notice when a manually-typed correction BG is implausible. Fail-closed — nothing
    /// is delivered.
    @State private var manualBGBlocked = false
    private enum Field { case carbs, bg, units }
    @FocusState private var focus: Field?
    /// Compact carbs/units `.fixedSize()` at normal text sizes; dropped at accessibility sizes
    /// where a fixed width would clip the digits.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// BG field binding that flags a user edit as `.manual` (auto-fills set `bg` directly + mark `.cgm`).
    private var bgField: Binding<String> {
        Binding(get: { bg }, set: { bg = $0; bgSource = $0.isEmpty ? .none : .manual })
    }
    /// Auto-fill the correction BG from the current CGM when the user hasn't typed their own and the
    /// reading is fresh; keeps it live as new readings arrive. No-op once the user edits the field.
    private func syncBGFromCGM() {
        guard bgSource != .manual, let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale else { return }
        // Write through the same display-unit funnel the field parses. A bare mg/dL Int into this
        // text field is later re-parsed as mmol (e.g. 124 → 2234 mg/dL) and corrupts the correction.
        let s = settings.glucoseDisplayUnit.format(mgdl: g)
        if bg != s { bg = s; bgSource = .cgm; if mode == .carbs { Task { await calculate() } } }
    }
    /// True when the shown dose leans on a CGM value that is now stale (advisory, not a block).
    private var staleCGMCorrection: Bool {
        mode == .carbs && bgSource == .cgm && model.snapshot.isGlucoseStale && (settings.glucoseDisplayUnit.parse(bg) ?? 0) > 0
    }
    /// Manually-typed correction BG outside 40–400 mg/dL. BolusMath silently drops an implausible-BG
    /// correction (correct for noisy auto-CGM, wrong for a typed hypo) so a low typed value would
    /// recommend MORE insulin — over-delivery in the unsafe direction. Gate the full implausible
    /// range here at compose/deliver; leave BolusMath's auto-CGM path untouched. Keys on `.manual`
    /// so an auto-filled `.cgm` value is never gated by this.
    private var manualBGImplausible: Bool {
        bgSource == .manual && settings.glucoseDisplayUnit.parse(bg).map { !GlucosePlausibility.isPlausible(mgdl: $0) } ?? false
    }

    /// Entry-parse boundary. `bg` is typed in `settings.glucoseDisplayUnit`; every call site uses
    /// `parse(bg)` — the only conversion to canonical mg/dL for `recommendBolus` / BolusMath /
    /// RemoteCommand. `nil` means no BG entered — callers MUST NOT coerce it to `0` (a fabricated
    /// glucose silently entering correction math).

    /// Keyboard: `.decimalPad` in mmol (a decimal is required), `.numberPad` in mg/dL.
    static func bgKeyboardType(for unit: GlucoseUnit) -> UIKeyboardType {
        unit == .mmol ? .decimalPad : .numberPad
    }
    /// Placeholder naming the active unit.
    static func bgPlaceholder(for unit: GlucoseUnit) -> String {
        unit == .mmol ? "mmol/L" : "mg/dL"
    }
    /// Accessibility label naming the active unit.
    static func bgAccessibilityLabel(for unit: GlucoseUnit) -> String {
        unit == .mmol ? "Blood glucose, mmol/L" : "Blood glucose, mg/dL"
    }

    /// Stale / CGM-changed messages: whole-phrase catalog variants per display unit, not a glued
    /// suffix. Canonical reading stays mg/dL.
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

    /// Stale-CGM dialog title is three-way so "CGM unavailable" never sits above a button that
    /// uses a stale-but-present reading. `newBG == -1` alone conflates no reading (carbs-only /
    /// cancel) with a stale reading that `staleBG` can still include.
    nonisolated static func staleCgmDialogTitle(newBG: Int?, staleBG: Int?) -> String {
        guard let newBG else { return "CGM updated" }
        if newBG != -1 { return "CGM updated" }                 // fresh-changed reading
        if staleBG != nil { return "CGM reading is stale" }     // stale-but-present (includable)
        return "CGM unavailable"                                 // no reading at all
    }

    private var staleCgmDialogTitle: String {
        Self.staleCgmDialogTitle(newBG: cgmUpdate?.newBG, staleBG: cgmUpdate?.staleBG)
    }

    private var carbs: Double { min(max(Double(carbsText) ?? 0, 0), 1000) }
    private var units: Double { Double(unitsText) ?? 0 }
    /// Advisory (never blocks): the user has adjusted the dose away from the calculator's recommendation
    /// for a carb bolus, so the carbs recorded on the pump won't match the delivered units. Uses the same
    /// conservative 0.10 U limit as the remote divergence guard.
    private var carbOverrideWarning: String? {
        // Don't cite the calculator's number when it's sized off a hardcoded guess.
        guard mode == .carbs, carbs > 0, let rec = recommendation, rec.displaysNumericDose, rec.recommendedUnits > 0,
              abs(units - rec.recommendedUnits) > AppModel.remoteDivergenceLimitUnits else { return nil }
        return String(format: "Delivering %.2f U for %.0f g — the calculator suggested %.2f U. The carbs will still be recorded on the pump with this dose.",
                      units, carbs, rec.recommendedUnits)
    }
    /// SG1 calc-override disclosure, or nil. Reads the pump's own op-115 target — never a hardcoded
    /// clinical constant — and never gates, changes, or delays delivery.
    private var sg1Disclosure: StackingGuard.Disclosure? {
        guard let rec = recommendation else { return nil }
        let disclosure = StackingGuard.calcOverride(enteredUnits: units, recommendedUnits: rec.recommendedUnits,
                                                     displaysNumericDose: rec.displaysNumericDose,
                                                     pumpIOBUnits: rec.iobUnits,
                                                     glucoseMgdl: model.snapshot.glucose,
                                                     targetMgdl: model.snapshot.targetBg)
        return disclosure.friction == .none ? nil : disclosure
    }
    /// SG2 max-bolus proximity disclosure, or nil. Anchored on the pump's own `maxBolusUnits` —
    /// never gates delivery. Beside "Exceeds pump max", not a replacement for it.
    private var sg2Disclosure: StackingGuard.Disclosure? {
        let disclosure = StackingGuard.maxBolusProximity(enteredUnits: units, maxBolusUnits: model.snapshot.maxBolusUnits)
        return disclosure.friction == .none ? nil : disclosure
    }
    /// Reservoir over-request disclosure when the entered dose exceeds the pump's own reported
    /// remaining. Never gates, clamps, or resizes — the pump enforces what it can deliver.
    private var insufficientReservoirDisclosure: StackingGuard.Disclosure? {
        let disclosure = StackingGuard.insufficientReservoir(enteredUnits: units, reservoirUnits: model.snapshot.reservoirUnits)
        return disclosure.friction == .none ? nil : disclosure
    }
    /// SG3a escalating-friction disclosure, or nil. Never a new dose decision. The message line
    /// always renders when SG3a fires; `stackingGuardFrictionEnabled` only caps which extra confirm
    /// / re-type tier is applied at the confirm seam (`sg3aAppliedFriction`).
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
    /// Friction actually applied at confirm: when the toggle is off, extra confirm / re-type cap
    /// down to `.disclose` — the message still shows, but those steps no longer gate delivery.
    private var sg3aAppliedFriction: StackingGuard.Friction {
        guard let f = sg3aDisclosure?.friction, f != .none else { return .none }
        return settings.stackingGuardFrictionEnabled ? f : .disclose
    }
    private var cgmAgeMinutes: Int? {
        model.snapshot.glucoseDate.map { max(0, Int(Date().timeIntervalSince($0) / 60)) }
    }
    /// Live CGM readout on the bolus screen (nil when no reading). Display-unit funnel.
    private var cgmReadout: String? {
        guard let g = model.snapshot.glucose else { return nil }
        let unit = settings.glucoseDisplayUnit
        let value = "\(unit.format(mgdl: g)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
        guard let d = model.snapshot.glucoseDate else { return value }
        return "\(value) · \(GlucoseFreshness.ageLabel(for: d, now: Date()))"
    }
    private var confirmMessage: String {
        var parts: [String] = []
        if staleCGMCorrection, let m = cgmAgeMinutes {
            parts.append("⚠️ Your CGM reading is \(m) min old — this correction may be based on outdated glucose.")
        }
        if let w = carbOverrideWarning { parts.append(w) }
        // SG3a escalating-friction text is not composed into the standard confirm dialog.
        // `sg3aDisclosure` / `sg3aAppliedFriction` (which the confirm seam still routes on) stay.
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
    /// Recommended-card copy when pump bolus settings haven't been read. Wording only — no
    /// control flow or dose logic depends on this string.
    static let awaitingPumpSettingsCopy = "Waiting to read this pump's bolus settings (carb ratio, correction factor, target). No dose can be recommended until they're read — check your pump connection."

    /// SG3a `.reenter`: re-typed value must equal `original` (within float tolerance). Any other
    /// value is rejected — never delivered as a resized amount. Internal so tests can pin that.
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

    /// One warning/disclosure line, classified blocking vs advisory. Presentation only — never
    /// re-derives the block decision (`rankedWarnings`). Internal so ranking tests can assert directly.
    struct BolusWarning: Identifiable, Equatable {
        enum Severity: Equatable { case blocking, advisory }
        /// Presentation-only color; NEVER what `rankedWarnings` sorts by — a grey blocker still
        /// classifies `.blocking`.
        enum Tone: Equatable {
            case danger, caution, neutral
            /// `nil` for `.danger` keeps the overMax label on the ambient body font.
            var font: Font? {
                switch self {
                case .danger: return nil
                case .caution: return .footnote
                case .neutral: return .caption
                }
            }
            var color: Color {
                switch self {
                case .danger: return AppTheme.low
                case .caution: return .orange
                case .neutral: return .secondary
                }
            }
        }
        let id: String
        let text: String
        let systemImage: String
        let severity: Severity
        let tone: Tone
    }

    /// Classification + ordering for on-screen warnings. Built from the same conditions that
    /// drive `canBolus` — `BolusGate.evaluate` is never called differently here. Blocking items
    /// (overMax, pumpNotLinked, bolusInFlight, childBlocked, noCartridge) first, then advisory,
    /// each group in source order. Presentation ORDER only: the set of items is unchanged, and a
    /// grey `.neutral` blocker still classifies `.blocking` (never demoted below an orange advisory).
    static func rankedWarnings(overMax: Bool, maxUnits: Double, sg2Message: String?, childBlocked: Bool,
                                pumpNotLinked: Bool, bolusInFlight: Bool, carbOverride: String?,
                                sg1Message: String?,
                                sg3aMessage: String?, insufficientReservoirMessage: String? = nil,
                                noCartridge: Bool = false) -> [BolusWarning] {
        var items: [BolusWarning] = []
        if overMax {
            items.append(BolusWarning(
                id: "overMax", text: "Exceeds pump max of \(String(format: "%.1f", maxUnits)) U",
                systemImage: "exclamationmark.triangle.fill", severity: .blocking, tone: .danger))
        }
        if let sg2 = sg2Message {
            items.append(BolusWarning(id: "sg2", text: sg2, systemImage: "exclamationmark.triangle",
                                       severity: .advisory, tone: .caution))
        }
        if childBlocked {
            items.append(BolusWarning(id: "childBlocked", text: "Bolus is disabled by child mode",
                                       systemImage: "lock.fill", severity: .blocking, tone: .neutral))
        }
        if pumpNotLinked {
            items.append(BolusWarning(id: "pumpNotLinked", text: BolusBlockReason.pumpNotLinked.userMessage,
                                       systemImage: "exclamationmark.triangle.fill", severity: .blocking, tone: .neutral))
        }
        if bolusInFlight {
            items.append(BolusWarning(id: "bolusInFlight", text: BolusBlockReason.bolusInFlight.userMessage,
                                       systemImage: "exclamationmark.triangle.fill", severity: .blocking, tone: .neutral))
        }
        if noCartridge {
            items.append(BolusWarning(id: "noCartridge", text: BolusBlockReason.noCartridge.userMessage,
                                       systemImage: "exclamationmark.triangle.fill", severity: .blocking, tone: .neutral))
        }
        if let w = carbOverride {
            items.append(BolusWarning(id: "carbOverride", text: w, systemImage: "pencil.and.outline",
                                       severity: .advisory, tone: .caution))
        }
        if let sg1 = sg1Message {
            items.append(BolusWarning(id: "sg1", text: sg1, systemImage: "exclamationmark.triangle",
                                       severity: .advisory, tone: .caution))
        }
        if let sg3a = sg3aMessage {
            items.append(BolusWarning(id: "sg3a", text: sg3a, systemImage: "exclamationmark.triangle",
                                       severity: .advisory, tone: .caution))
        }
        if let insufficientReservoir = insufficientReservoirMessage {
            items.append(BolusWarning(id: "insufficientReservoir", text: insufficientReservoir,
                                       systemImage: "exclamationmark.triangle", severity: .advisory, tone: .caution))
        }
        // Stable partition: blocking first, then advisory — never re-sorted by tone/color.
        return items.filter { $0.severity == .blocking } + items.filter { $0.severity == .advisory }
    }

    var body: some View {
        withSG3aFriction(
            Group {
                if embedded { content } else { NavigationStack { content } }
            }
        )
    }

    // Regular width: cap the Form at readable width and center it. Compact: no frame.
    // Presentation only — delivery / gating / confirm / friction paths are untouched.
    private var content: some View {
        Group {
            if horizontalSizeClass == .regular {
                formContent
                    .frame(maxWidth: AppTheme.iPadReadableContentMaxWidth, alignment: .top)
                    .frame(maxWidth: .infinity)
            } else {
                formContent
            }
        }
    }

    private var formContent: some View {
        withBolusConfirmationDialogs(formSections)
    }

    // Form sections split so the type-checker can compile this view.
    @ViewBuilder private var bolusModePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Carbs").tag(BolusMode.carbs)
            Text("Units").tag(BolusMode.units)
        }
        .pickerStyle(.segmented)
        .disabled(delivering || preparingDeliver)
    }

    @ViewBuilder private var carbsEntrySection: some View {
        Section("Entry") {
            HStack(spacing: 6) {
                // Value + unit share one large tap target — the TextField is ~one glyph wide.
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
    }

    @ViewBuilder private var recommendedSection: some View {
        if let rec = recommendation {
            Section("Recommended") {
                if rec.displaysNumericDose {
                    LabeledContent("Recommended dose", value: String(format: "%.2f U", rec.recommendedUnits)).fontWeight(.semibold)
                    if settings.showBolusReasoning {
                        DisclosureGroup("Show reasoning", isExpanded: $showReasoning) {
                            LabeledContent("Carb + correction", value: String(format: "%.2f U", rec.recommendedUnits + rec.iobUnits))
                            // Grey + age the IOB row when the active-insulin read is stale.
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
                    // Pump bolus settings unread this session — any numeric dose would be sized off
                    // a hardcoded CR/ISF/target guess. Suppress the number; delivery is already
                    // blocked (CalcInputGate → .blockNoTherapy).
                    Label(BolusEntryView.awaitingPumpSettingsCopy, systemImage: "hourglass")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Ranked warning list — extracted so the 11-arg `rankedWarnings` call type-checks.
    @ViewBuilder private var deliverWarnings: some View {
        // Dose-blocking conditions must stay visually dominant — ranked above advisories.
        // Same conditions that drive `canBolus` / Deliver `.disabled`; presentation order only.
        ForEach(Self.rankedWarnings(
            overMax: overMax, maxUnits: maxUnits,
            // SG disclosure TEXT is nil'd so `rankedWarnings` has no SG advisory to rank.
            // `sg1Disclosure`/`sg2Disclosure`/`sg3aDisclosure` and `sg3aAppliedFriction` stay.
            sg2Message: nil,
            childBlocked: !settings.childAllows(.bolus),
            pumpNotLinked: model.bolusGate(amount: units, minimum: 0.05).reason == .pumpNotLinked,
            bolusInFlight: model.bolusGate(amount: units, minimum: 0.05).reason == .bolusInFlight,
            carbOverride: carbOverrideWarning,
            sg1Message: nil,
            sg3aMessage: nil,
            insufficientReservoirMessage: insufficientReservoirDisclosure?.message,
            noCartridge: model.bolusGate(amount: units, minimum: 0.05).reason == .noCartridge
        )) { item in
            Label(item.text, systemImage: item.systemImage)
                .font(item.tone.font)
                .foregroundStyle(item.tone.color)
        }
    }

    @ViewBuilder private var deliverSection: some View {
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
                // Units mode has no CGM in the carbs Entry section. Surface the same stale-styled
                // readout here — awareness, not a blocking confirm (nothing is silently dropped in
                // units mode, and a modal on every units bolus would be alert fatigue).
                if mode == .units, let readout = cgmReadout {
                    let staleR = model.snapshot.isGlucoseStale
                    Label(readout, systemImage: staleR ? "sensor.tag.radiowaves.forward" : "sensor.tag.radiowaves.forward.fill")
                        .font(.caption)
                        .foregroundStyle(staleR ? .orange : .secondary)
                }
                deliverWarnings
                Button { confirming = true } label: {
                    HStack { Spacer(); Text(preparingDeliver ? "Checking CGM…" : "Bolus \(String(format: "%.2f U", units))"); Spacer() }
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.insulin)
                .disabled(!model.bolusGate(amount: units, minimum: 0.05).canBolus || preparingDeliver)
                // The button reads its full dose ("Deliver 2.50 units"), not just "Bolus".
                .accessibilityLabel(preparingDeliver ? "Checking CGM" : "Deliver \(String(format: "%.2f", units)) units")
            }
        }
    }

    @ViewBuilder private var extendedBolusSection: some View {
        // Extended bolus — Settings plus pump capability (don't offer a combo a pump can't deliver).
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

    @ViewBuilder private var formSections: some View {
        Form {
            // Carbs entry only when the backend supports the pump's bolus calculator.
            if model.capabilities.supportsCarbEntry { bolusModePicker }

            if mode == .carbs {
                carbsEntrySection
                recommendedSection
            }

            deliverSection

            extendedBolusSection
        }
        // Floating top toast, not a Form Section — `.overlay` so it doesn't consume Form space.
        .overlay(alignment: .top) {
            if let banner = successBanner {
                BolusSuccessBannerView(banner: banner)
                    .padding(.horizontal)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle("Bolus")
        .navigationBarTitleDisplayMode(.inline)
        // Scale to the largest accessibility text size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
        .onAppear {
            if !modeInitialized {
                mode = model.capabilities.supportsCarbEntry ? settings.defaultBolusMode : .units
                modeInitialized = true
            }
            // Freshest CGM on open, then auto-fill the correction BG (never from a stale value).
            // Same unit funnel as `syncBGFromCGM` — never a bare mg/dL Int into the typed field.
            if bg.isEmpty, let g = model.snapshot.glucose, !model.snapshot.isGlucoseStale { bg = settings.glucoseDisplayUnit.format(mgdl: g); bgSource = .cgm }
            if mode == .carbs { Task { await calculate() } }
            // Also refresh calc inputs (CR/ISF/target + IOB) on open so the recommendation isn't
            // built from a ~10-min-stale cache.
            Task { await model.refreshGlucoseNow(); await model.refreshCalcInputsNow(); syncBGFromCGM() }
        }
        // Recompute live as carbs / BG change — no "Calculate" button.
        .onChange(of: carbsText) { _, _ in if mode == .carbs { Task { await calculate() } } }
        .onChange(of: bg) { _, _ in if mode == .carbs { Task { await calculate() } } }
        .onChange(of: mode) { _, newMode in
            // Mode switch is a fresh entry. A carbs-calculator dose can be unverified
            // (`inputsVerified == false`); the warned-override gate is carbs-mode-only, so a stale
            // carb dose left in Units would deliver with no acknowledgement. Clear so Units starts
            // empty (Deliver stays disabled until the user dials).
            recommendation = nil
            unitsText = ""
            calcInputPrompt = nil
            acceptedOverride = nil
            calcInputBlocked = false
            if newMode == .carbs { Task { await calculate() } }
        }
        // Keep CGM-sourced BG live; a reading that lands ≤2 s before deliver still re-checks.
        .onChange(of: model.snapshot.glucoseDate) { _, _ in lastCGMChangeAt = Date(); syncBGFromCGM() }
        // Remote-approval resolution: only a non-nil→nil transition is a result. Use the frozen
        // staged amount — never a false "delivered" at staging, never on reject/timeout.
        .onChange(of: model.pendingApproval) { oldValue, newValue in
            guard let resolved = oldValue, newValue == nil else { return }
            let signal: BolusConfirmation.Signal = model.lastError == nil ? .delivered : .failed
            // Prefer the ledger's actual committed units over the staged requested amount.
            present(BolusConfirmation.banner(for: signal, units: model.lastDeliveredUnits ?? resolved.units,
                                             message: model.lastError))
        }
        // Tick the age label every 60s; only spend a pump read when the shown value is aging
        // (>90s). Self-stops after ~30 min so a screen left open can't drain battery.
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
    }

    /// Confirm / CGM-update / extended / calc-input dialogs as a separate modifier group so the
    /// Form's chain type-checks. Same rendered dialogs and gating.
    @ViewBuilder
    private func withBolusConfirmationDialogs<V: View>(_ view: V) -> some View {
        view
        .confirmationDialog("Deliver \(String(format: "%.2f U", units))?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Deliver \(String(format: "%.2f U", units))", role: .destructive) { handleStandardConfirm() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .confirmationDialog(staleCgmDialogTitle,
                            isPresented: Binding(get: { cgmUpdate != nil },
                                                 set: { if !$0 { cgmUpdate = nil } }),
                            titleVisibility: .visible) {
            if let u = cgmUpdate {
                if u.newBG == -1 {
                    // Stale-CGM three-way: (1) include the stale reading (insulin-increasing, only
                    // when a stale reading exists); (2) carbs-only; (3) cancel (sends nothing).
                    if let sbg = u.staleBG, let su = u.staleUnits {
                        // Same unit funnel as the message: button and body must show one number.
                        Button("Include \(settings.glucoseDisplayUnit.format(mgdl: sbg)) \(settings.glucoseDisplayUnit == .mmol ? "mmol/L" : "mg/dL") → \(String(format: "%.2f U", su))") {
                            let ext = u.extended; let carbsOnlyUnits = u.newUnits; cgmUpdate = nil
                            // Re-verify includable age at tap. If the reading aged past the cap
                            // since the dialog opened, fail closed to carbs-only rather than dosing
                            // an insulin-increasing correction off a now-too-old reading.
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
                    // Same unit funnel as the message.
                    Button("Use \(settings.glucoseDisplayUnit.format(mgdl: u.newBG)) \(settings.glucoseDisplayUnit == .mmol ? "mmol/L" : "mg/dL") → \(String(format: "%.2f U", u.newUnits))") {
                        // Label already shows the converted figure; the field it writes must match.
                        bg = settings.glucoseDisplayUnit.format(mgdl: u.newBG); bgSource = .cgm; unitsText = Self.trimUnits(u.newUnits)
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
        // Pump never reported bolus settings this attempt. Cancel-only (fail-closed) — never a
        // dose off a guessed carb ratio, and no false "last-known" label.
        .alert("Pump settings not read yet", isPresented: $calcInputBlocked) {
            Button("OK", role: .cancel) { calcInputBlocked = false }   // sends NOTHING
        } message: {
            Text("faBolus hasn't read this pump's bolus settings (carb ratio / correction factor / target) yet, so it can't size a dose. Wait a moment for the pump to connect, then try again.")
        }
        // Manual BG outside the plausible range: cancel-only (fail-closed) — never passed to
        // `recommendBolus`, where BolusMath would silently drop a low's dose-reducing correction.
        .alert("Check your glucose", isPresented: $manualBGBlocked) {
            Button("OK", role: .cancel) { manualBGBlocked = false }   // sends NOTHING
        } message: {
            Text("That glucose reading looks out of range — re-check your glucose before dosing.")
        }
        // Calc inputs weren't confirmed fresh. Warned two-way override — never a silent deliver.
        // Cancel sends nothing. No drop/zero-IOB option (that is the maximum-dose direction).
        .confirmationDialog(calcInputDialogTitle,
                            isPresented: Binding(get: { calcInputPrompt != nil },
                                                 set: { if !$0 { calcInputPrompt = nil } }),
                            titleVisibility: .visible) {
            if let p = calcInputPrompt {
                Button(calcInputUseLabel(p), role: .destructive) {
                    // Accept the override for this attempt and re-enter attemptDeliver — skips the
                    // warning gate but still runs fresh-CGM + divergence + stale-CGM three-way.
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

    /// SG3a extra-confirm / re-type dialogs as a separate modifier group so each chain type-checks.
    @ViewBuilder
    private func withSG3aFriction<V: View>(_ view: V) -> some View {
        view
            // SG3a extra confirm: one more step beyond standard confirm. Same captured dose;
            // Cancel sends nothing; Deliver proceeds to unchanged `attemptDeliver`.
            .confirmationDialog("Confirm again — deliver \(String(format: "%.2f U", sgOriginalUnits))?",
                                isPresented: $sgConfirmExtra, titleVisibility: .visible) {
                Button("Deliver \(String(format: "%.2f U", sgOriginalUnits))", role: .destructive) {
                    Task { await attemptDeliver(extended: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This dose is well above what the pump's calculator suggested. Confirm once more before delivering — the amount will not change.")
            }
            // SG3a re-type: must match `sgOriginalUnits` exactly. A mismatch is rejected and
            // re-prompted — never a resized delivered amount. SwiftUI dismisses on every tap, so
            // a mismatch re-presents this same alert on the next runloop.
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
    }

    /// Standard-confirm Deliver tap → SG3a friction route. Observability only: same mapping
    /// `handleStandardConfirm` already implements.
    enum StandardConfirmRoute { case reenter, confirmExtra, deliver }

    /// Internal so `StackingGuardDeliverInvariantTests` can assert all four mappings.
    static func standardConfirmRoute(for friction: StackingGuard.Friction) -> StandardConfirmRoute {
        switch friction {
        case .reenter: return .reenter
        case .confirmExtra: return .confirmExtra
        case .disclose, .none: return .deliver
        }
    }

    /// Route the standard confirm tap through the friction actually applied. Capture `units` into
    /// `sgOriginalUnits` now (freeze once) so a field edit under a later dialog can't substitute a
    /// different dose. Extra confirm / re-type never change `units`.
    ///
    /// Extra-confirm / re-type flags flip on the next runloop so the next modal is requested after
    /// the standard dialog finishes dismissing (otherwise the first tap is a dead tap). Timing
    /// only — which gate each tier reaches is unchanged.
    private func handleStandardConfirm() {
        sgOriginalUnits = units
        switch Self.standardConfirmRoute(for: sg3aAppliedFriction) {
        case .reenter:
            sgReenterText = ""
            sgReenterMismatch = false
            DispatchQueue.main.async { self.sgReenter = true }
        case .confirmExtra:
            DispatchQueue.main.async { self.sgConfirmExtra = true }
        case .deliver:
            Task { await attemptDeliver(extended: false) }
        }
    }

    /// Re-type alert message. Never implies the mismatched number was accepted or delivered.
    private var sgReenterMessage: String {
        sgReenterMismatch
            ? "That doesn't match \(String(format: "%.2f", sgOriginalUnits)) U — nothing was delivered. Re-enter \(String(format: "%.2f", sgOriginalUnits)) U exactly to confirm, or cancel."
            : "This dose is far above what the pump's calculator suggested. Re-enter \(String(format: "%.2f", sgOriginalUnits)) U exactly to confirm — the amount will not change."
    }

    // Calc-input prompt copy, keyed on which input(s) were unconfirmed.
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
            return StaleTherapyPrompt.warningMessage(profile: p.assumedProfile, therapyDate: p.therapyDate, unit: settings.glucoseDisplayUnit)
        case .both:
            return StaleTherapyPrompt.warningMessage(profile: p.assumedProfile, therapyDate: p.therapyDate, unit: settings.glucoseDisplayUnit)
                + "\n\n" + StaleIobPrompt.warningMessage(iobUnits: p.iobUnits, iobDate: p.iobDate)
        }
    }

    private func durationLabel(_ min: Int) -> String {
        min % 60 == 0 ? "\(min / 60)h" : "\(min)m"
    }

    private func calculate() async {
        // Nothing entered yet → no recommendation card.
        guard carbs > 0 || (settings.glucoseDisplayUnit.parse(bg) ?? 0) > 0 else { recommendation = nil; unitsText = ""; return }
        // Generation token: a newer edit supersedes this calc so an out-of-order async result
        // can't overwrite the field with a stale dose.
        calcSeq &+= 1
        let seq = calcSeq
        calcInputPrompt = nil       // a changed dose re-requires the per-attempt freshness override
        acceptedOverride = nil      // …and drops any override accepted for a prior compose
        calcInputBlocked = false    // …and clears any prior "settings not read" block
        let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: settings.glucoseDisplayUnit.parse(bg))
        guard seq == calcSeq else { return }
        recommendation = rec
        // Never pre-fill units with a dose sized off a hardcoded CR/ISF/target guess. Field stays
        // empty; delivery is blocked (CalcInputGate → .blockNoTherapy) until the pump reports.
        unitsText = (rec.displaysNumericDose && rec.recommendedUnits > 0) ? Self.trimUnits(rec.recommendedUnits) : ""
    }

    /// Immutable confirmed bolus: captured once at confirm; delivery never re-reads live `@State`.
    private struct FrozenBolus { let units: Double; let carbsGrams: Double?; let bgMgdl: Int?; let iobUnits: Double?; let extendedNow: Double? ; let extendedDurationMin: Int? }

    /// Validate a correction against a fresh CGM, then freeze + deliver. Shared by standard and
    /// extended paths. Diverges → ask; fresh & close → use fresh; stale/missing → fail closed
    /// (drop the correction, carbs-only) rather than dose off the stale on-screen value.
    private func attemptDeliver(extended: Bool) async {
        // Manual implausible BG blocked here, before any recommend/deliver. Passing a sub-40 typed
        // value onward would let BolusMath silently drop the dose-reducing correction — over-delivery
        // during an apparent hypo. Auto-CGM (`.cgm`) is never gated here.
        if manualBGImplausible {
            manualBGBlocked = true
            return   // sends NOTHING
        }
        // Deliver-time gate is `CalcInputGate.decide` — carbs mode only, keys on `!inputsVerified`
        // before any staleness flag. An accepted override this attempt skips the warning but still
        // runs fresh-CGM + divergence + stale-CGM three-way. Remotes fail closed in `resolveRemoteDose`.
        if let rec = recommendation, calcInputPrompt == nil, !calcInputBlocked {
            switch CalcInputGate.decide(isCarbsMode: mode == .carbs, inputsVerified: rec.inputsVerified,
                                        iobStale: rec.iobStale, therapyStale: rec.therapyStale,
                                        therapyAvailable: !rec.therapyUnavailable,
                                        overrideAccepted: acceptedOverride != nil) {
            case .proceed:
                break   // fall through to the deliver machinery below
            case .blockNoTherapy:
                // Pump never reported bolus settings — any dose would be a hardcoded guess.
                // Cancel-only (fail-closed); retry once the pump reports.
                calcInputBlocked = true
                return
            case .prompt(let kind):
                // Override dose off last-known + on-screen BG is the button/divergence baseline.
                // Actual delivered dose is the deliver-time recompute (or min(baseline, fresh)).
                let pre = await model.recommendBolus(carbsGrams: carbs, bgMgdl: settings.glucoseDisplayUnit.parse(bg),
                                                     allowStaleIob: kind.allowStaleIob, allowStaleTherapy: kind.allowStaleTherapy)
                calcInputPrompt = CalcInputPrompt(kind: kind, extended: extended, overrideUnits: pre.recommendedUnits,
                                                  allowStaleIob: kind.allowStaleIob, allowStaleTherapy: kind.allowStaleTherapy,
                                                  iobUnits: rec.iobUnits, iobDate: rec.iobDate,
                                                  assumedProfile: rec.assumedProfile, therapyDate: rec.therapyParamsDate)
                return
            }
        }
        // Consume the accepted override for this attempt only, then clear so it can't persist.
        let ov = acceptedOverride
        acceptedOverride = nil
        preparingDeliver = true
        defer { preparingDeliver = false }
        // Every CGM-sourced carbs bolus — meal+correction AND correction-only (carbs == 0).
        // Gating this on `carbs > 0` previously let a correction-only bolus dose off a stale CGM.
        if mode == .carbs, bgSource == .cgm {
            let justChanged = lastCGMChangeAt.map { Date().timeIntervalSince($0) <= 2 } ?? false
            // Divergence baseline: override button's shown dose, else on-screen `units`.
            let priorUnits = ov?.baseline ?? units
            await model.refreshGlucoseNow()
            // Force calc inputs fresh before the deliver-time recompute so the 0.10 U guard also
            // catches an input change (clinician edit / profile segment / IOB drift). Any accepted
            // override is threaded into every recompute here.
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
                // Within tolerance deliver the on-screen dose, bound to the BG it was computed
                // from — not the just-pulled `g` (that would attach glucose the dose wasn't derived from).
                await deliverFrozen(freeze(units: priorUnits, bg: settings.glucoseDisplayUnit.parse(bg), extended: extended))
                return
            }
            // Stale/missing CGM — never silently correct off the on-screen value, even if a stale
            // IOB/therapy override was accepted (that override is not glucose). Three-way:
            // includeStale / carbs-only / cancel. `newBG = -1` selects the carbs-only branch.
            let carbsOnly = await model.recommendBolus(carbsGrams: carbs, bgMgdl: nil,
                                                       allowStaleIob: ov?.allowStaleIob ?? false,
                                                       allowStaleTherapy: ov?.allowStaleTherapy ?? false)
            // Offer "include stale" only inside `(staleAfter, maxIncludableStaleness]`. Older than
            // the cap: carbs-only / cancel — never compute a correction off it.
            if let sg = model.snapshot.glucose,
               StaleBolusPrompt.mayOfferInclude(glucoseMgdl: sg, glucoseDate: model.snapshot.glucoseDate) {
                let withStale = await model.recommendBolus(carbsGrams: carbs, bgMgdl: sg,
                                                           allowStaleIob: ov?.allowStaleIob ?? false,
                                                           allowStaleTherapy: ov?.allowStaleTherapy ?? false)
                cgmUpdate = CGMUpdatePrompt(newBG: -1, newUnits: carbsOnly.recommendedUnits, oldUnits: priorUnits,
                                           extended: extended, staleBG: sg, staleUnits: withStale.recommendedUnits)
            } else {
                // No includable reading: none present, or older than the cap. Carbs-only / cancel.
                cgmUpdate = CGMUpdatePrompt(newBG: -1, newUnits: carbsOnly.recommendedUnits, oldUnits: priorUnits,
                                           extended: extended)
            }
            return
        }
        // No CGM-correction here: Units mode, or carbs with a manual/absent BG. With an accepted
        // override, never more than `ov.baseline` (what the owner consented to) — min(baseline, fresh)
        // never over-delivers vs consent or a fresh read. Units mode freezes the number the user dialed.
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
        // Freeze calculator IOB from the recommendation — not a live snapshot at delivery time.
        FrozenBolus(units: u, carbsGrams: carbs > 0 ? carbs : nil, bgMgdl: bgVal,
                    iobUnits: recommendation?.iobUnits,
                    extendedNow: extended ? u * Double(extendedNowPercent) / 100 : nil,
                    extendedDurationMin: extended ? extendedDurationMin : nil)
    }

    /// Deliver exactly the frozen proposal — the only place that calls the backend.
    private func deliverFrozen(_ f: FrozenBolus) async {
        delivering = true
        if let now = f.extendedNow, let dur = f.extendedDurationMin {
            await model.deliverExtendedBolus(totalUnits: f.units, nowUnits: now, durationMinutes: dur,
                                             carbsGrams: f.carbsGrams, bgMgdl: f.bgMgdl, iobUnits: f.iobUnits)
        } else {
            // Carbs/BG go to the pump as recorded metadata; carb recording is centralized in the model.
            await model.deliverBolus(units: f.units, carbsGrams: f.carbsGrams, bgMgdl: f.bgMgdl, iobUnits: f.iobUnits)
        }
        delivering = false
        // Sync-path confirmation from the model's already-updated state. Child-mode reverse-approval
        // stages `pendingApproval` and resolves later via `.onChange`. Report ledger actual units,
        // not the frozen request — a mid-flight cancel/partial isn't overstated.
        let bannerUnits = model.lastDeliveredUnits ?? f.units
        let extended: BolusConfirmation.ExtendedDetail?
        if let now = f.extendedNow, !model.lastDeliveredWasCancelled {
            extended = BolusConfirmation.ExtendedDetail(nowUnits: now, totalUnits: f.units, durationMinutes: f.extendedDurationMin ?? 0)
        } else {
            extended = nil
        }
        // `lastError` is the truthful non-success message; unused when the signal is `.delivered`.
        present(BolusConfirmation.banner(for: confirmationSignal(), units: bannerUnits, extended: extended,
                                         message: model.lastError))
        finishDelivery()
    }

    /// Outcome of a just-completed attempt, read from the model — never a delivery decision.
    private func confirmationSignal() -> BolusConfirmation.Signal {
        if model.pendingApproval != nil { return .staged }
        return model.lastError == nil ? .delivered : .failed
    }

    /// Present the toast, announce it, auto-dismiss after ~4s (~6s with VoiceOver).
    private func present(_ banner: BolusSuccessBanner?) {
        guard let banner else { return }
        // Compare this presentation's token, not content — two identical-amount deliveries would
        // otherwise let the first timer dismiss the second toast.
        let token = banner.token
        withAnimation(.easeInOut) { successBanner = banner }
        AccessibilityNotification.Announcement("\(banner.primary), \(banner.secondary)").post()
        let dwellSeconds: UInt64 = UIAccessibility.isVoiceOverRunning ? 6 : 4
        Task {
            try? await Task.sleep(nanoseconds: dwellSeconds * 1_000_000_000)
            if successBanner?.token == token {
                withAnimation(.easeInOut) { successBanner = nil }
            }
        }
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
    /// `.fixedSize()` at normal text sizes, not at accessibility sizes (a fixed width clips digits).
    @ViewBuilder func compactFixedSize(_ isAccessibility: Bool) -> some View {
        if isAccessibility { self } else { self.fixedSize() }
    }
}

