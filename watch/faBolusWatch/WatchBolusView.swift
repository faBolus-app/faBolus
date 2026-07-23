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
    @State private var sent = false

    private var isCarbs: Bool { mode == .carbs }
    private var step: Double { isCarbs ? model.carbIncrement : model.bolusIncrement }
    private var maxAmount: Double { isCarbs ? 200 : max(model.maxBolusUnits, 0.05) }
    private var amountLabel: String { isCarbs ? "\(Int(amount)) g" : String(format: "%.2f U", amount) }
    /// In carbs mode, the units the phone would deliver (like the Garmin/Mac preview).
    private var estUnits: Double? { (isCarbs && amount > 0) ? model.estimatedUnits(forCarbs: amount) : nil }

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
                .disabled(amount <= 0 || !model.reachable || !model.pumpConnected)

                if model.reachable && !model.pumpConnected {
                    Label("Pump not connected", systemImage: "wifi.slash")
                        .font(.caption2).foregroundStyle(.orange)
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
