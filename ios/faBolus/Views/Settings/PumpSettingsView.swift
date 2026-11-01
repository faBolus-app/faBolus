import PhoneApp
import SwiftUI
import faBolusCore

struct PumpSettingsView: View {
    @Bindable var model: AppModel
    @State private var showPairing = false
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section("Pump") {
                if let pairing = model.pairing {
                    LabeledContent("Model", value: pairing.model.displayName)
                    if let name = pairing.advertisedName { LabeledContent("Name", value: name) }
                    LabeledContent("Status", value: status)
                    if let api = model.pump.apiVersion?.value {
                        LabeledContent("API", value: "\(api.major).\(api.minor)")
                    }
                    if let failure = model.linkFailure {
                        Text(PumpMessages.text(failure)).font(.footnote).foregroundStyle(.orange)
                    } else if let reason = model.lastDisconnect, model.pump.link != .connected {
                        Text(PumpMessages.text(reason)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Pair a different pump or new code") { showPairing = true }
                    Button("Forget this pump", role: .destructive) { confirmForget = true }
                } else {
                    Text("No pump paired.").foregroundStyle(.secondary)
                    Button("Connect a pump") { showPairing = true }
                }
            }
            Section {
                LabeledContent("History", value: historyText)
                Button("Sync history now") { Task { await model.syncHistory() } }.disabled(
                    model.pump.link != .connected)
            } footer: {
                Text("faBolus reads the pump's history every 15 minutes and keeps it on this phone.")
            }
        }
        .navigationTitle("Pump")
        .sheet(isPresented: $showPairing) { PairingSheet(model: model) { showPairing = false } }
        .confirmationDialog("Forget this pump?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget pump", role: .destructive) { Task { await model.forgetPump() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "faBolus disconnects and removes the pairing and the logbook. To use the pump again you pair with a new code. A bolus whose outcome is unknown still has to be confirmed on the pump."
            )
        }
    }

    private var status: String {
        switch model.pump.link {
        case .connected: return "Connected"
        case .authenticating: return "Authenticating"
        case .connecting: return "Connecting"
        case .scanning: return "Searching"
        case .disconnected: return "Disconnected"
        }
    }

    private var historyText: String {
        switch model.historySync {
        case .idle(let last):
            return last.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet"
        case .syncing: return "Syncing…"
        case .paused: return "Paused (link dropped)"
        case .error(let message): return message
        }
    }
}
