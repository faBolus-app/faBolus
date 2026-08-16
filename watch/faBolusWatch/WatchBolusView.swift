import SwiftUI
import faBolusCore

/// Bolus entry, at parity with the phone + Garmin: pick **Units** or **Carbs** (default from
/// Settings), set the amount with the Digital Crown (step = the watch increment), then confirm.
/// The watch confirms on-device (like the Garmin) and the iPhone delivers directly through the
/// validated signed path — carbs are converted to units on the phone. Experimental.
struct WatchBolusView: View {
    @Bindable var model: WatchModel
    @Environment(\.dismiss) private var dismiss

    // N12 (Dynamic Type): the big amount readout scales instead of a fixed 32 pt.
    @ScaledMetric(relativeTo: .largeTitle) private var amountFontSize: CGFloat = 32

    private enum Mode: String { case carbs, units }
    @State private var mode: Mode = .carbs
    @State private var modeInit = false
    @State private var amount = 0.0        // units or grams, per mode
    @State private var confirming = false
    /// P15 Addendum B: the stale-CGM three-way is showing (include the stale reading / carbs only / cancel).
    @State private var stalePrompt = false
    @State private var sent = false

    private var isCarbs: Bool { mode == .carbs }
    private var step: Double { isCarbs ? model.carbIncrement : model.bolusIncrement }
    private var maxAmount: Double { isCarbs ? 200 : max(model.maxBolusUnits, 0.05) }
    private var amountLabel: String { isCarbs ? "\(Int(amount)) g" : String(format: "%.2f U", amount) }
    /// Phase 4 (mmol/L display-unit support) — this screen has NO glucose-entry field (carbs/units
    /// only, adjusted by the crown), so there is no `Int(bg)`-style parse boundary to fix here
    /// (Task 3 N/A per the plan's own escape hatch). It DOES render the phone's current glucose
    /// reading (view-only, `model.glucose`) — that render routes through the received unit, matching
    /// the plan's must_haves truth ("bolus entry" renders in the received unit) and WatchHUDView/
    /// WatchDetailsView's treatment.
    private var unit: GlucoseUnit { model.glucoseDisplayUnit }
    /// In carbs mode, the units the phone would deliver (like the Garmin/Mac preview).
    private var estUnits: Double? { (isCarbs && amount > 0) ? model.estimatedUnits(forCarbs: amount) : nil }

    /// The shared `BolusGate` for the watch, fed from the relayed pump state — inline (like the Mac)
    /// because this one control spans carbs grams + insulin units, so the max differs by mode. Adds the
    /// in-flight gate the watch lacked (it checked only reachability + pump link): a dose already running
    /// elsewhere now disables Deliver instead of letting the watch start a second, diverging one (v3
    /// defect group D). Read-only stays enforced by hiding the affordance (`WatchApp` / `WatchHUDView`);
    /// it's passed here too as defense-in-depth.
    private var gate: (canBolus: Bool, reason: BolusBlockReason?) {
        // §2.3 + read-only, defense-in-depth (the affordance is already hidden upstream). Distinguish the
        // two so the reason shown is accurate: read-only vs "watch bolusing turned off on the phone".
        let access: AccessPolicy.AccessDecision = model.watchBolusAllowed
            ? .allow
            : .deny(model.readOnly ? .remotesReadOnly : .remoteBolusDisabled)
        return BolusGate.evaluate(reachable: model.reachable, linked: model.pumpConnected,
                                  bolusInFlight: model.bolusInFlight,
                                  amount: amount, minimum: isCarbs ? 1 : 0.05, maximum: maxAmount,
                                  access: access)
    }
    /// Why Deliver is disabled, for the reasons worth showing here — not the bounds reasons (the crown
    /// can't overshoot the max, and 0 just keeps Deliver disabled). Replaces the old pump-not-connected-
    /// only label, so a dose already in flight is now explained too. Exhaustive by design.
    private var blockMessage: String? {
        switch gate.reason {
        case .pumpNotLinked, .bolusInFlight, .remoteUnreachable, .accessDenied, .noCartridge:
            return gate.reason?.userMessage
        case .belowMinimum, .aboveMax, .none:
            return nil
        }
    }

    var body: some View {
        Group {
            if sent { statusView } else { entryView }
        }
        .navigationTitle("Bolus")
        .onAppear {
            if !modeInit { mode = Mode(rawValue: model.defaultMode) ?? .carbs; modeInit = true }
            // Poll once on entering (not continuously — battery): ask the phone to force a fresh CGM
            // read so the estimate is current. The host also re-reads at delivery + runs the guard.
            model.requestStatus(forceGlucose: true)
        }
    }

    private var entryView: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    modeButton(.carbs, "Carbs")
                    modeButton(.units, "Units")
                }

                // §11 (group A / C7): the current glucose + its AGE, right on the bolus screen — so a
                // stale reading (which the carb estimate rides on) is visible before you confirm, rather
                // than an old value passing for current. Value greyed + age orange once stale.
                if let g = model.glucose, !model.glucoseHidden {
                    HStack(spacing: 4) {
                        Text(unit.format(mgdl: g)).fontWeight(.semibold)
                        if !model.isGlucoseStale { Text(model.trend) }
                        if let age = model.ageLabel {
                            Text("· \(age)").foregroundStyle(model.isGlucoseStale ? .orange : .secondary)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(model.isGlucoseStale ? .secondary : .primary)
                    // N12: one spoken element; "stale" injected when the reading is de-emphasized.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(bolusGlucoseLabel(g))
                }

                // DIF-ux: the active-insulin the estimate subtracts, greyed + aged when the host couldn't
                // confirm it fresh — so a stale IOB is visible before you confirm. VIEW-ONLY on a remote.
                if model.iobUnits > 0 || model.iobDate != nil {
                    HStack(spacing: 4) {
                        Text(String(format: "IOB %.2f U", model.iobUnits))
                        if let a = model.iobAgeLabel {
                            Text("· \(a)").foregroundStyle(model.isIobStale ? .orange : .secondary)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(model.isIobStale ? .secondary : .primary)
                    // N12: one spoken element; "stale" injected when the IOB read is de-emphasized.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(bolusIobLabel)
                }

                // DIF-ux pre-warn (carbs mode): the estimate rides on last-known IOB / therapy the host
                // couldn't confirm fresh. VIEW/PRE-WARN ONLY — a remote NEVER offers an include-last-known
                // override and NEVER sends one; the phone offers it and stays the authoritative dose gate.
                if isCarbs, amount > 0, model.isIobStale || model.isTherapyStale {
                    Text(calcInputPreWarn)
                        .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                }

                Text(amountLabel)
                    .font(.system(size: amountFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(.indigo)
                    .focusable()
                    .digitalCrownRotation($amount, from: 0, through: maxAmount, by: step,
                                          sensitivity: .medium, isContinuous: false)
                    // N12: the crown-adjustable amount reads as an adjustable value ("Carbs, 30 g").
                    .accessibilityLabel(isCarbs ? "Carbs, grams" : "Bolus, units")
                    .accessibilityValue(amountLabel)
                Text("Turn crown to set").font(.caption2).foregroundStyle(.secondary)
                if let u = estUnits {
                    Text(String(format: "≈ %.2f U", u)).font(.caption).foregroundStyle(.secondary)
                }

                // B2 (S1+O3): the controller auto-correction disclosure — reconstructed locally from the
                // mirrored controllerVariant + controlIQEnabled, matching the phone bolus screen. Facts
                // only; NEVER gates/changes/delays the dose.
                if let ambient = model.autoCorrectionAmbient {
                    Label(ambient, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let lockout = model.autoCorrectionLockout {
                    Label(lockout, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                }

                Button { confirming = true } label: {
                    Label("Bolus \(amountLabel)", systemImage: "drop.fill")
                }
                .tint(.indigo)
                .disabled(!gate.canBolus)
                .accessibilityLabel("Bolus \(amountLabel)")

                if let m = blockMessage {
                    Text(m).font(.caption2).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Text("Experimental").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .confirmationDialog("Deliver \(amountLabel)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Deliver \(amountLabel)", role: .destructive) { deliver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let u = estUnits {
                Text(String(format: "≈ %.2f U will be delivered. faBolus is experimental and not FDA-cleared.", u))
            } else {
                Text("faBolus is experimental and not FDA-cleared.")
            }
        }
        // P15 Addendum B: a carb bolus while the CGM reading is stale must not SILENTLY drop the
        // correction. Present the shared three-way choice — include the stale reading (insulin-INCREASING,
        // per-attempt), bolus for carbs only (drop the correction — today's behavior), or cancel (send
        // NOTHING). Warned iff stale at confirm; a fresh reading (or units mode / no reading) bypasses it.
        .confirmationDialog("CGM reading is stale", isPresented: $stalePrompt, titleVisibility: .visible) {
            if let g = model.glucose {
                Button(includeStaleLabel(g)) { model.deliverCarbs(amount, includeStaleBG: true); sent = true }
            }
            Button(carbsOnlyLabel, role: .destructive) { model.deliverCarbs(amount); sent = true }
            Button("Cancel", role: .cancel) {}   // sends NOTHING
        } message: {
            Text(staleMessage)
        }
    }

    /// DIF-ux pre-warn copy (carbs mode) — names which calc input(s) the host couldn't confirm current, so
    /// the wrist estimate's basis is honest. The phone offers the actual use-last-known override + delivers.
    private var calcInputPreWarn: String {
        if model.isIobStale && model.isTherapyStale {
            return "Active insulin & pump settings aren't confirmed current — the phone will confirm before delivering."
        }
        if model.isTherapyStale {
            return "Pump settings aren't confirmed current — the phone will confirm before delivering."
        }
        return "Active insulin isn't confirmed current — the phone will confirm before delivering."
    }

    /// The include-stale button label: the stale value and the dose it WOULD produce (the correction is
    /// added back, so this is insulin-increasing vs carbs-only).
    private func includeStaleLabel(_ g: Int) -> String {
        if let u = model.estimatedUnits(forCarbs: amount, includeStaleBG: true) {
            return "Include \(unit.format(mgdl: g)) → " + String(format: "%.2f U", u)
        }
        return "Include \(unit.format(mgdl: g)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
    }
    /// The carbs-only button label: the correction dropped (today's silent behavior, now acknowledged).
    private var carbsOnlyLabel: String {
        if let u = model.estimatedUnits(forCarbs: amount) {
            return "Carbs only → " + String(format: "%.2f U", u)
        }
        return "Carbs only"
    }
    /// Shared warning lead (identical wording across surfaces) when the age is known; a compact fallback
    /// when the reading has no source timestamp (still stale, but no age to name).
    private var staleMessage: String {
        if let g = model.glucose, let d = model.glucoseDate {
            // Gap closure (04-07, own-sweep finding beyond 04-VERIFICATION/04-REVIEW): the shared
            // `StaleBolusPrompt.warningMessage` bakes in a bare " mg/dL" literal (correct for the
            // intentionally-unconverted Mac target, which also calls it) — the Watch has its own
            // unit-aware `unit`/`GlucoseUnit.format`, so build the identical wording locally
            // instead, matching every other converted surface on this screen.
            let value = "\(unit.format(mgdl: g)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
            return "Your CGM reading (\(value)) is \(GlucoseFreshness.ageLabel(for: d, now: Date())) "
                + "and was left out of this dose. Include it in the correction, bolus for carbs only, or cancel?"
        }
        return "Your CGM reading is stale and was left out of this dose. Include it, bolus for carbs only, or cancel."
    }

    private var statusView: some View {
        VStack(spacing: 8) {
            Image(systemName: statusIcon).font(.largeTitle).foregroundStyle(statusColor)
            Text(model.statusMessage ?? "Delivering…").font(.footnote).multilineTextAlignment(.center)
            if inProgress {
                Button(role: .destructive) { model.cancel() } label: {
                    Label("Cancel bolus", systemImage: "stop.fill")
                }.tint(.red)
            } else {
                Button("Done") { dismiss() }
            }
        }
        .padding()
        // Auto-close a couple seconds after a successful delivery only. Cancelled/failed stay on
        // screen (Done to exit) so an accidental cancel or a failure isn't missed.
        .onChange(of: model.lastStatus) { _, s in
            if s == .delivered {
                Task { try? await Task.sleep(nanoseconds: 2_500_000_000); dismiss() }
            }
        }
    }

    private func modeButton(_ m: Mode, _ title: String) -> some View {
        Button {
            if mode != m { mode = m; amount = 0 }
        } label: {
            Text(title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(mode == m ? .indigo : .gray.opacity(0.4))
        // N12: name the mode and mark the active one selected (otherwise conveyed only by tint).
        .accessibilityLabel(title)
        .accessibilityAddTraits(mode == m ? .isSelected : [])
    }

    /// N12: spoken description of the bolus-screen glucose line, with "stale" when de-emphasized.
    private func bolusGlucoseLabel(_ g: Int) -> String {
        var parts = ["Glucose \(unit.format(mgdl: g))"]
        if !model.isGlucoseStale { parts.append(model.trend) } else { parts.append("stale") }
        if let age = model.ageLabel { parts.append(age) }
        return parts.joined(separator: ", ")
    }
    /// N12: spoken description of the bolus-screen active-insulin line, with "stale" when de-emphasized.
    private var bolusIobLabel: String {
        var parts = [String(format: "Active insulin %.2f units", model.iobUnits)]
        if model.isIobStale { parts.append("stale") }
        if let a = model.iobAgeLabel { parts.append(a) }
        return parts.joined(separator: ", ")
    }

    private func deliver() {
        // P15 Addendum B: a carb bolus while the CGM reading is stale routes to the three-way choice
        // (include the stale reading / carbs only / cancel) instead of delivering directly. Fresh
        // readings, units mode, and no-reading all bypass it and deliver as before.
        if isCarbs && amount > 0 && model.staleCarbWarnNeeded {
            stalePrompt = true
            return
        }
        if isCarbs { model.deliverCarbs(amount) } else { model.deliverUnits(amount) }
        sent = true
    }

    private var inProgress: Bool {
        switch model.lastStatus {
        case .delivered, .failed, .outOfRange, .cancelled: return false
        default: return true
        }
    }
    private var statusIcon: String {
        switch model.lastStatus {
        case .delivered: return "checkmark.circle.fill"
        case .failed, .outOfRange: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        default: return "hourglass"
        }
    }
    private var statusColor: Color {
        switch model.lastStatus {
        case .delivered: return .green
        case .failed, .outOfRange: return .red
        case .cancelled: return .orange
        default: return .indigo
        }
    }
}
