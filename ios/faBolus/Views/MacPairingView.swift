import SwiftUI
import UIKit

/// Settings → Remotes & devices → Remote access → pairing. Start a pairing window — a **QR to scan**
/// (recommended, higher-entropy) or a **one-time code** to type — see the connected remote, and forget
/// paired remotes. Works for the Mac app and a parent iPhone. The handshake itself runs in
/// `PeerRemoteHost`; this view only drives `MacPairingCoordinator`.
struct MacPairingView: View {
    @State private var pairing = MacPairingCoordinator.shared
    private var hostName: String { UIDevice.current.name }   // must match PeerRemoteHost's BLE name

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
                if pairing.activeCode != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let qr = pairing.qrString(hostName: hostName) {
                            Text("Scan this on the remote (Mac or parent iPhone)")
                                .font(.subheadline).foregroundStyle(.secondary)
                            QRCodeView(string: qr).frame(maxWidth: .infinity, alignment: .center)
                        } else if let code = pairing.activeCode {
                            Text("Enter this code on the remote")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(spaced(code))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .textSelection(.enabled)
                        }
                        if let exp = pairing.codeExpiry {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let secs = max(0, Int(exp.timeIntervalSinceNow))
                                Text(secs > 0 ? "Expires in \(secs / 60):\(String(format: "%02d", secs % 60))"
                                              : "Expired — tap Cancel and start again")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        Button("Cancel", role: .cancel) { pairing.cancelPairing() }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        pairing.beginPairing(viaQR: true)
                    } label: {
                        Label("Pair with QR code", systemImage: "qrcode")
                    }
                    Button {
                        pairing.beginPairing(viaQR: false)
                    } label: {
                        Label("Pair with a code instead", systemImage: "textformat.123")
                    }
                }
            } header: {
                Text("Pair a remote")
            } footer: {
                Text("Pair the faBolus Mac app or a parent's iPhone — it shows status and can send boluses your phone delivers. QR is recommended (higher-entropy, just scan it); a typed code works if the remote has no camera. Only a remote you pair can connect.")
            }

            if !pairing.pairedMacs.isEmpty {
                Section("Paired remotes") {
                    ForEach(pairing.pairedMacs) { mac in
                        HStack {
                            Image(systemName: mac.name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "laptopcomputer")
                                .foregroundStyle(.secondary)
                            Text(mac.name).lineLimit(1)
                            Spacer()
                            Button("Forget", role: .destructive) { pairing.forget(mac.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Remotes")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Remote paired", isPresented: Binding(
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
