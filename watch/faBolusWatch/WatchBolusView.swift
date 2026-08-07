import SwiftUI
import faBolusCore

/// Bolus entry, at parity with the phone + Garmin: pick **Units** or **Carbs** (default from
/// Settings), set the amount with the Digital Crown (step = the watch increment), then confirm.
/// The watch confirms on-device (like the Garmin) and the iPhone delivers directly through the
/// validated signed path — carbs are converted to units on the phone. Experimental.
struct WatchBolusView: View {
    @Bindable var model: WatchModel
    @Environment(\.dismiss) private var dismiss

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
        case .pumpNotLinked, .bolusInFlight, .remoteUnreachable, .accessDenied:
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
                        Text("\(g)").fontWeight(.semibold)
                        if !model.isGlucoseStale { Text(model.trend) }
                        if let age = model.ageLabel {
                            Text("· \(age)").foregroundStyle(model.isGlucoseStale ? .orange : .secondary)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(model.isGlucoseStale ? .secondary : .primary)
                }

                Text(amountLabel)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.indigo)
                    .focusable()
                    .digitalCrownRotation($amount, from: 0, through: maxAmount, by: step,
                                          sensitivity: .medium, isContinuous: false)
                Text("Turn crown to set").font(.caption2).foregroundStyle(.secondary)
                if let u = estUnits {
                    Text(String(format: "≈ %.2f U", u)).font(.caption).foregroundStyle(.secondary)
                }

                Button { confirming = true } label: {
                    Label("Bolus \(amountLabel)", systemImage: "drop.fill")
                }
                .tint(.indigo)
                .disabled(!gate.canBolus)

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

    /// The include-stale button label: the stale value and the dose it WOULD produce (the correction is
    /// added back, so this is insulin-increasing vs carbs-only).
    private func includeStaleLabel(_ g: Int) -> String {
        if let u = model.estimatedUnits(forCarbs: amount, includeStaleBG: true) {
            return "Include \(g) → " + String(format: "%.2f U", u)
        }
        return "Include \(g) mg/dL"
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
            return StaleBolusPrompt.warningMessage(glucoseMgdl: g, glucoseDate: d)
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
