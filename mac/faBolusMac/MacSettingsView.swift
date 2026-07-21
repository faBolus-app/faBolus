import SwiftUI
import faBolusCore

/// Connection pane (shown inside the menu-bar popover): pick and pair the iPhone this Mac controls.
/// The Mac discovers iPhones running faBolus on the local network (MultipeerConnectivity); pairing
/// remembers one and reconnects automatically. The Mac never touches the pump — it relays to the
/// paired iPhone. Laid out for the narrow popover (no fixed frame / Form chrome).
struct MacConnectionView: View {
    var model: MacRemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.pairing.connected ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(model.pairing.connected ? "Connected" : "Not connected")
                    .font(.callout)
                Spacer()
                if let paired = model.pairing.pairedPhone {
                    Text(paired).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if model.pairing.pairedPhone != nil {
                Button("Forget this iPhone", role: .destructive) { model.pairing.forget() }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            Divider()

            Text("Available iPhones").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.pairing.discoveredPhones.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.pairing.discoveredPhones, id: \.self) { name in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        Text(name).lineLimit(1)
                        Spacer()
                        if model.pairing.pairedPhone == name {
                            Image(systemName: "checkmark")
                                .foregroundStyle(model.pairing.connected ? .green : .secondary)
                        } else {
                            Button("Pair") { model.pairing.pair(with: name) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }

            Text("Both devices must be on the same Wi-Fi. Open faBolus on the iPhone at least once so it can advertise.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
