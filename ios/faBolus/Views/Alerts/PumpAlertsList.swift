import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// The pump's open alerts, each with what the phone can do about it: Clear once this pump has accepted a
/// clear, a secondary "Try clearing from phone" while that isn't known, and otherwise "Clear it on the
/// pump". All three follow the alert's one `remoteClear` value.
struct PumpAlertsList: View {
    @Bindable var model: AppModel
    @State private var clearing: Set<String> = []
    @State private var messages: [String: String] = [:]

    private var alerts: [PumpAlert] { model.display.alerts?.value ?? [] }

    /// When the list was read, while it's older than the pump-status window: the pump may show other
    /// alerts by now.
    private var readAge: String? {
        guard let read = model.display.alerts else { return nil }
        let display = model.pumpDisplay(now: model.now)
        guard read.valueIfFresh(within: model.freshness.pumpStatusStaleAfter, now: model.now) == nil else { return nil }
        return display.age(read.measuredAt)
    }

    /// A clear needs the pump connected.
    private var canClear: Bool { model.pump.link == .connected }

    var body: some View {
        VStack(spacing: 8) {
            if let readAge, !alerts.isEmpty {
                Text("Read from the pump \(readAge). Check the pump for its current alerts.")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(alerts, id: \.key) { alert in row(alert) }
        }
    }

    private func row(_ alert: PumpAlert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(alert.kind)).foregroundStyle(color(alert.kind)).font(.headline).accessibilityHidden(
                true)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title).font(.subheadline).fontWeight(.semibold)
                if !alert.detail.isEmpty {
                    Text(alert.detail).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
                switch AlertClearOffer(alert) {
                case .clear: EmptyView()
                case .tryFromPhone:
                    Button("Try clearing from phone") { clear(alert) }
                        .font(.caption).buttonStyle(.borderless).disabled(clearing.contains(alert.key) || !canClear)
                case .clearOnPump:
                    Text(AlertClearOffer.clearOnPumpText).font(.caption).foregroundStyle(.secondary)
                }
                if let message = messages[alert.key] { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 8)
            if AlertClearOffer(alert) == .clear {
                Button {
                    clear(alert)
                } label: {
                    if clearing.contains(alert.key) {
                        ProgressView()
                    } else {
                        Text("Clear").font(.caption).fontWeight(.semibold)
                    }
                }
                .buttonStyle(.bordered).disabled(clearing.contains(alert.key) || !canClear)
            }
        }
        .padding(10)
        .background(color(alert.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func clear(_ alert: PumpAlert) {
        clearing.insert(alert.key)
        messages[alert.key] = nil
        Task {
            let outcome = await model.dismiss(alert)
            messages[alert.key] = AlertClearOffer.message(after: outcome)
            clearing.remove(alert.key)
        }
    }

    private func icon(_ k: PumpAlertKind) -> String {
        switch k {
        case .alarm: return "exclamationmark.octagon.fill"
        case .cgmAlert: return "sensor.fill"
        case .reminder: return "bell.fill"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ k: PumpAlertKind) -> Color {
        switch k {
        case .alarm: return AppTheme.low
        case .cgmAlert: return AppTheme.high
        case .reminder, .alert: return .orange
        }
    }
}

extension PumpAlert {
    /// Unique per open alert: an alarm and a malfunction on the same bit are two alerts.
    var key: String { "\(kind.rawValue)-\(id)-\(malfunctionCode.map(String.init) ?? "")" }
}

/// The Alerts tab: the pump's alerts, then the phone's own notifications that are showing.
struct AlertsScreenView: View {
    @Bindable var model: AppModel

    private var phoneAlerts: [ActiveAlertRow] {
        (model.alertSnapshot?.active ?? []).filter { $0.pumpAlert == nil }.map {
            ActiveAlertRow(title: $0.title, body: $0.body)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if (model.display.alerts?.value ?? []).isEmpty && phoneAlerts.isEmpty {
                        ContentUnavailableView(
                            "No active alerts", systemImage: "checkmark.circle",
                            description: Text("Pump alerts and alarms will appear here.")
                        )
                        .padding(.top, 40)
                    } else {
                        PumpAlertsList(model: model)
                        ForEach(phoneAlerts, id: \.self) { a in
                            Card(icon: "iphone", tint: .orange, title: a.title) { Text(a.body).font(.subheadline) }
                        }
                        if (model.display.alerts?.value ?? []).contains(where: { $0.kind == .cgmAlert }) {
                            Text(
                                "A CGM alert like “high glucose” is condition-based: the pump keeps raising it while the reading is high, so it may come back until glucose is in range."
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Alerts")
        }
    }
}

private struct ActiveAlertRow: Hashable {
    let title: String
    let body: String
}
