import SwiftUI
import faBolusCore

/// modern banner listing active pump alerts/alarms, each with a Clear button that sends a
/// signed dismiss to the pump — so the user can clear them without reaching for the pump.
struct AlertsBannerView: View {
    @Bindable var model: AppModel
    @State private var clearing: Set<Int> = []

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.activeNotifications) { n in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(n.kind))
                        .foregroundStyle(color(n.kind))
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).font(.subheadline).fontWeight(.semibold)
                        if !n.detail.isEmpty {
                            Text(n.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if n.isDismissable && model.capabilities.supportsAlertClear {
                        Button {
                            clearing.insert(n.id)
                            Task { await model.dismissNotification(n); clearing.remove(n.id) }
                        } label: {
                            if clearing.contains(n.id) { ProgressView() }
                            else { Text("Clear").font(.caption).fontWeight(.semibold) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(clearing.contains(n.id))
                    }
                }
                .padding(10)
                .background(color(n.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
    }

    private func icon(_ k: PumpAlertKind) -> String {
        switch k {
        case .alarm: return "exclamationmark.octagon.fill"
        case .cgmAlert: return "sensor.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
    private func color(_ k: PumpAlertKind) -> Color {
        switch k {
        case .alarm: return AppTheme.low          // red — most serious
        case .cgmAlert: return AppTheme.high
        default: return .orange
        }
    }
}
