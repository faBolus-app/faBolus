import SwiftUI

/// Loop-style Digital Crown dial-to-bolus. The watch confirms intent (first confirm) and sends
/// a units-only request; the iPhone runs the second confirm + delivery interlock.
/// SALINE bench boluses only.
struct WatchBolusView: View {
    @Bindable var model: WatchModel
    @Environment(\.dismiss) private var dismiss

    private let maxUnits = 10.0
    @State private var units = 0.0
    @State private var sent = false

    var body: some View {
        VStack(spacing: 10) {
            if sent {
                VStack(spacing: 8) {
                    Image(systemName: statusIcon).font(.largeTitle).foregroundStyle(statusColor)
                    Text(model.statusMessage ?? "Sent").font(.footnote).multilineTextAlignment(.center)
                    // While still in progress, offer a red Cancel; once final, a Done button.
                    if inProgress {
                        Button(role: .destructive) { model.cancel() } label: {
                            Label("Cancel bolus", systemImage: "stop.fill")
                        }.tint(.red)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            } else {
                Text(String(format: "%.2f U", units))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.indigo)
                    .focusable()
                    .digitalCrownRotation($units, from: 0, through: maxUnits, by: model.bolusIncrement,
                                          sensitivity: .medium, isContinuous: false)
                Text("Turn crown to set").font(.caption2).foregroundStyle(.secondary)
                Button {
                    model.requestBolus(units: units); sent = true
                } label: {
                    Label("Request on iPhone", systemImage: "arrow.up.forward")
                }
                .tint(.indigo)
                .disabled(units < 0.05)
                Text("Saline · bench only").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Bolus")
    }

    /// Still awaiting confirm or delivering (not a final delivered/failed/cancelled state).
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
