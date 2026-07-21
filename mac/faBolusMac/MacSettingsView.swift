import SwiftUI
import faBolusCore

/// Settings → Connection: pick and pair the iPhone this Mac controls. The Mac discovers iPhones
/// running faBolus on the local network (MultipeerConnectivity); pairing remembers one and
/// reconnects to it automatically. The Mac never touches the pump — it relays to the paired iPhone.
struct MacSettingsView: View {
    var model: MacRemoteModel

    var body: some View {
        Form {
            Section("iPhone connection") {
                HStack(spacing: 8) {
                    Circle().fill(model.pairing.connected ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    Text(model.pairing.connected ? "Connected" : "Not connected")
                    Spacer()
                    if let paired = model.pairing.pairedPhone {
                        Text(paired).foregroundStyle(.secondary)
                    }
                }
                if model.pairing.pairedPhone != nil {
                    Button("Forget this iPhone", role: .destructive) { model.pairing.forget() }
                }
            }

            Section("Available iPhones") {
                if model.pairing.discoveredPhones.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching for iPhones running faBolus…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.pairing.discoveredPhones, id: \.self) { name in
                        HStack {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            Text(name)
                            Spacer()
                            if model.pairing.pairedPhone == name {
                                Label(model.pairing.connected ? "Paired" : "Pairing…", systemImage: "checkmark")
                                    .labelStyle(.iconOnly).foregroundStyle(.green)
                            } else {
                                Button("Pair") { model.pairing.pair(with: name) }
                            }
                        }
                    }
                }
            }

            Section {
                Text("Both devices must be on the same Wi-Fi network. The iPhone must have faBolus open at least once so it can advertise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 340)
    }
}
