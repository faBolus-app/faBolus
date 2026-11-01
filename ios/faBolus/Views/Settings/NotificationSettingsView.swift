import Alerts
import PhoneApp
import SwiftUI
import faBolusCore

/// One switch per kind of notification, all on by default. "Pump disconnected" is a delay instead, and
/// the bolus result can't be turned off.
struct NotificationSettingsView: View {
    @Bindable var model: AppModel
    @State private var policy = AlertPolicy()
    @State private var loaded = false

    var body: some View {
        Form {
            if let banner = model.alertSnapshot?.banners.first(where: { $0 == .notificationsOff }) {
                Section {
                    Text(banner.body)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text(banner.title)
                }
            }
            Section {
                Picker("Pump disconnected", selection: delay) {
                    ForEach(AlertPolicy.PumpDisconnectDelay.allCases, id: \.self) { Text(label($0)).tag($0) }
                }
                ForEach(AlertPolicy.switchableCategories.filter { $0 != .pumpDisconnect }, id: \.self) { category in
                    Toggle(category.label, isOn: binding(category))
                }
            } footer: {
                Text(
                    "“Pump disconnected” waits this long for the pump to come back before it notifies, then reminds you 15 and 30 minutes after the drop."
                )
            }
            Section {
                LabeledContent("Bolus result", value: "Always on")
            } footer: {
                Text(
                    "A bolus's result, and the notice when its outcome is unknown, can't be turned off. Bolus results, pump disconnected, connection unstable and the backup urgent low can break through Focus when iOS allows it."
                )
            }
        }
        .navigationTitle("Notifications")
        .task {
            policy = await model.alertPolicy()
            loaded = true
        }
    }

    private var delay: Binding<AlertPolicy.PumpDisconnectDelay> {
        Binding(
            get: { policy.pumpDisconnectDelay },
            set: {
                policy.pumpDisconnectDelay = $0
                save()
            })
    }

    private func binding(_ category: NotificationBroker.Category) -> Binding<Bool> {
        Binding(
            get: { policy.isOn(category) },
            set: {
                policy.setOn($0, for: category)
                save()
            })
    }

    private func save() {
        guard loaded else { return }
        let policy = policy
        Task { await model.setAlertPolicy(policy) }
    }

    private func label(_ delay: AlertPolicy.PumpDisconnectDelay) -> String {
        switch delay {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 min"
        case .fiveMinutes: return "After 5 min"
        case .tenMinutes: return "After 10 min"
        case .fifteenMinutes: return "After 15 min"
        case .thirtyMinutes: return "After 30 min"
        case .never: return "Never"
        }
    }
}
