import SwiftUI

/// Settings → Watch & Garmin → "Mac remote". Start a pairing window (shows a one-time code the user
/// types on the Mac), see the connected Mac, and forget paired Macs. The handshake itself runs in
/// `PeerRemoteHost`; this view only drives `MacPairingCoordinator`.
struct MacPairingView: View {
    @State private var pairing = MacPairingCoordinator.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Circle().fill(pairing.connected ? .green : .secondary).frame(width: 9, height: 9)
                    Text(pairing.connected ? "Connected" : "Not connected")
                    Spacer()
                    if let name = pairing.connectedName {
                        Text(name).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            Section {
                if let code = pairing.activeCode {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter this code on your Mac")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(spaced(code))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .textSelection(.enabled)
                        if let exp = pairing.codeExpiry {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let secs = max(0, Int(exp.timeIntervalSinceNow))
                                Text(secs > 0 ? "Expires in \(secs / 60):\(String(format: "%02d", secs % 60))"
                                              : "Expired — tap Cancel and start again")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        Text("On the Mac: open faBolus → Settings → Connection, choose this iPhone, then type the code.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { pairing.cancelPairing() }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        pairing.beginPairing()
                    } label: {
                        Label("Pair a Mac", systemImage: "laptopcomputer.and.arrow.down")
                    }
                }
            } header: {
                Text("Pair a Mac")
            } footer: {
                Text("The faBolus Mac app is a remote — it shows status and can send boluses your phone delivers. Pairing requires this one-time code so only a Mac you approve can connect.")
            }

            if !pairing.pairedMacs.isEmpty {
                Section("Paired Macs") {
                    ForEach(pairing.pairedMacs) { mac in
                        HStack {
                            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                            Text(mac.name).lineLimit(1)
                            Spacer()
                            Button("Forget", role: .destructive) { pairing.forget(mac.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Mac remote")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Mac paired", isPresented: Binding(
            get: { pairing.justPaired != nil },
            set: { if !$0 { pairing.justPaired = nil } }
        )) {
            Button("OK", role: .cancel) { pairing.justPaired = nil }
        } message: {
            Text("“\(pairing.justPaired ?? "")” can now control this phone. It will reconnect automatically from now on.")
        }
    }

    /// "123456" -> "123 456" for readability.
    private func spaced(_ code: String) -> String {
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<mid]) \(code[mid...])"
    }
}
