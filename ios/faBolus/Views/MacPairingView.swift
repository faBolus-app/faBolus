import SwiftUI
import UIKit
import faBolusCore

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
                Section {
                    ForEach(pairing.pairedMacs) { mac in
                        NavigationLink {
                            RemotePeerPermissionsView(clientId: mac.id, name: mac.name)
                        } label: {
                            HStack {
                                Image(systemName: mac.name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "laptopcomputer")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mac.name).lineLimit(1)
                                    Text(pairing.policy(for: mac.id).isViewOnly ? "View only" : "Can control")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("Paired remotes") } footer: {
                    Text("Tap a device to set what it can do (view-only vs. control) or to forget it.")
                }
            }
        }
        .navigationTitle("Remotes")
        .navigationBarTitleDisplayMode(.inline)
        .alert("“\(pairing.justPaired ?? "")” paired", isPresented: Binding(
            get: { pairing.justPaired != nil },
            set: { if !$0 { clearJustPaired() } }
        )) {
            // Audit A-11: only a QR-paired (high-entropy) peer may be offered control; a manual-code
            // peer is view-only until re-paired via QR.
            if let id = pairing.justPairedClientId, RemotePeerPolicyStore.canGrantControl(id) {
                Button("Allow control") {
                    pairing.setPolicy(.fullControl, for: id)
                    clearJustPaired()
                }
            }
            Button("View only", role: .cancel) {
                if let id = pairing.justPairedClientId { pairing.setPolicy(.viewOnly, for: id) }
                clearJustPaired()
            }
        } message: {
            if let id = pairing.justPairedClientId, RemotePeerPolicyStore.canGrantControl(id) {
                Text("Choose what this device may do. View only shows status but can't deliver boluses or change the pump — you can change this anytime under Paired remotes.")
            } else {
                Text("This device was paired with a 6-digit code, so it stays view-only (it can see status but can't deliver boluses or change the pump). To let it control the pump, forget it and re-pair by scanning the QR code.")
            }
        }
    }

    private func clearJustPaired() { pairing.justPaired = nil; pairing.justPairedClientId = nil }

    /// "123456" -> "123 456" for readability.
    private func spaced(_ code: String) -> String {
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<mid]) \(code[mid...])"
    }
}

/// Per-device permissions for one paired remote (Mac or iPhone). A prominent **Read-only** toggle
/// (view status only) plus, when off, the granular actions and how its boluses are confirmed. Saved
/// immediately to `RemotePeerPolicyStore` and enforced by `PeerRemoteHost`.
struct RemotePeerPermissionsView: View {
    let clientId: String
    let name: String
    @State private var pairing = MacPairingCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var policy = RemotePeerPolicy.viewOnly
    /// Audit A-11: only a QR-paired peer may be granted control; a manual-code peer is locked view-only.
    private var canControl: Bool { RemotePeerPolicyStore.canGrantControl(clientId) }

    var body: some View {
        Form {
            Section {
                Toggle("Read-only (view status only)", isOn: Binding(
                    get: { policy.isViewOnly || !canControl },
                    set: { ro in policy = ro ? .viewOnly : .fullControl; save() }
                ))
                .disabled(!canControl)
            } footer: {
                if canControl {
                    Text("When read-only, “\(name)” can see status but can't deliver boluses or change the pump.")
                } else {
                    Text("“\(name)” was paired with a 6-digit code, so it stays view-only. To let it control the pump, forget it and re-pair by scanning the QR code.")
                }
            }

            if canControl && !policy.isViewOnly {
                Section("Allowed actions") {
                    ForEach(RemotePermission.allCases) { p in
                        Toggle(p.label, isOn: Binding(
                            get: { policy.allows(p) },
                            set: { on in if on { policy.permissions.insert(p) } else { policy.permissions.remove(p) }; save() }
                        ))
                    }
                }
                Section {
                    Picker("Boluses", selection: Binding(
                        get: { policy.approvalMode },
                        set: { policy.approvalMode = $0; save() }
                    )) {
                        ForEach(RemoteApprovalMode.allCases) { Text($0.label).tag($0) }
                    }
                } header: { Text("Bolus confirmation") } footer: {
                    Text("“Remote confirms” lets the device deliver after confirming on its own screen; “I approve on this phone” makes each bolus wait for your OK here.")
                }
            }

            Section {
                Button("Forget this device", role: .destructive) { pairing.forget(clientId); dismiss() }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { policy = pairing.policy(for: clientId) }
    }

    private func save() { pairing.setPolicy(policy, for: clientId) }
}
