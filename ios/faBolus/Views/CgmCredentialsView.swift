import SwiftUI
import faBolusCore

/// Enter the cloud-follower credentials for the CGM failover sources. Non-secret fields persist to
/// UserDefaults (`GlucoseSourceConfig`); passwords/tokens go to the Keychain (`CredentialStore`).
/// Applied on the next launch (like the source/backend selection). Sensitive fields use SecureField.
struct CgmCredentialsView: View {
    @Environment(\.dismiss) private var dismiss

    // LibreLinkUp (Libre 2/3)
    @State private var libreUser = ""
    @State private var librePass = ""
    @State private var libreRegion = ""
    // Dexcom Share (G6 / last-resort)
    @State private var shareUser = ""
    @State private var sharePass = ""
    @State private var shareRegion = "us"
    // Nightscout (universal)
    @State private var nsURL = ""
    @State private var nsToken = ""
    // Dexcom G5/G6/ONE (direct, passive "follow the Dexcom app")
    @State private var g6TransmitterID = ""

    @State private var saved = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $libreUser)
                    .textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $librePass)
                TextField("Region (optional, e.g. us, eu)", text: $libreRegion)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("FreeStyle Libre 2/3 — LibreLinkUp")
            } footer: {
                Text("Your LibreLinkUp follower account (share from the LibreLink app). Region is auto-detected on first login if left blank.")
            }

            Section {
                TextField("Username", text: $shareUser)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $sharePass)
                Picker("Region", selection: $shareRegion) {
                    Text("US").tag("us")
                    Text("Outside US").tag("ous")
                }
            } header: {
                Text("Dexcom Share (last resort)")
            } footer: {
                Text("Your Dexcom account with Share enabled and uploading. Cloud-only and unreliable — a last-resort feed for G6.")
            }

            Section {
                TextField("Site URL (https://…)", text: $nsURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Token (optional)", text: $nsToken)
            } header: {
                Text("Nightscout (any CGM)")
            } footer: {
                Text("A Nightscout site already receiving your CGM data. Token is optional if the site allows unauthenticated reads.")
            }

            Section {
                TextField("Transmitter ID (6 chars, optional)", text: $g6TransmitterID)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            } header: {
                Text("Dexcom G5 / G6 / ONE (direct)")
            } footer: {
                Text("Keep the official Dexcom app running — faBolus reads the transmitter passively alongside it. The transmitter ID just helps pick the right sensor if several are nearby; no login needed.")
            }

            if saved {
                Label("Saved — reopen the app to apply.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.footnote)
            }

            Section {
                Button {
                    save(); saved = true
                    Task { await testSelectedSource() }
                } label: {
                    HStack {
                        Label("Save & test failover source", systemImage: "bolt.horizontal.circle")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing)
                if let r = testResult {
                    Text(r).font(.footnote)
                        .foregroundStyle(r.hasPrefix("✅") ? .green : (r.hasPrefix("⚠️") ? .orange : .secondary))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Test")
            } footer: {
                Text("Saves these credentials, then builds the **selected** failover source (Settings → CGM source) and tries to pull a live reading right now — so you can verify it works without disconnecting the pump or reopening the app.")
            }
        }
        .navigationTitle("CGM credentials")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(); saved = true }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        libreUser = GlucoseSourceConfig.string("librelinkup.username") ?? ""
        librePass = CredentialStore.get(account: "librelinkup.password") ?? ""
        libreRegion = GlucoseSourceConfig.string("librelinkup.region") ?? ""
        shareUser = GlucoseSourceConfig.string("dexcomshare.username") ?? ""
        sharePass = CredentialStore.get(account: "dexcomshare.password") ?? ""
        shareRegion = GlucoseSourceConfig.string("dexcomshare.region") ?? "us"
        nsURL = GlucoseSourceConfig.string("nightscout.url") ?? ""
        nsToken = CredentialStore.get(account: "nightscout.token") ?? ""
        g6TransmitterID = GlucoseSourceConfig.string("dexcomg6.transmitterId") ?? ""
    }

    private func save() {
        func trimmed(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        GlucoseSourceConfig.set(trimmed(libreUser), "librelinkup.username")
        CredentialStore.set(trimmed(librePass), account: "librelinkup.password")
        GlucoseSourceConfig.set(trimmed(libreRegion)?.lowercased(), "librelinkup.region")

        GlucoseSourceConfig.set(trimmed(shareUser), "dexcomshare.username")
        CredentialStore.set(trimmed(sharePass), account: "dexcomshare.password")
        GlucoseSourceConfig.set(shareRegion, "dexcomshare.region")

        GlucoseSourceConfig.set(trimmed(nsURL), "nightscout.url")
        CredentialStore.set(trimmed(nsToken), account: "nightscout.token")
        GlucoseSourceConfig.set(trimmed(g6TransmitterID)?.uppercased(), "dexcomg6.transmitterId")
    }

    /// Build the currently-selected failover source, start it, and poll up to ~10 s for a live
    /// reading — a self-contained diagnostic that verifies credentials + connectivity in-app.
    @MainActor private func testSelectedSource() async {
        testing = true; testResult = nil
        defer { testing = false }
        guard let descriptor = GlucoseSourceRegistry.selected(),
              let source = GlucoseSourceRegistry.makeSelected() else {
            testResult = "No failover source selected. Pick one in Settings → CGM source, then test."
            return
        }
        await source.start()
        for _ in 0..<10 {   // ~10 s: cloud pollers + BLE need a moment for the first reading
            if let s = source.latest {
                let age = Int(max(0, Date().timeIntervalSince(s.date)))
                let ageStr = age < 60 ? "\(age)s ago" : "\(age / 60) min ago"
                let staleNote = GlucoseFreshness.isStale(s.date) ? " — STALE" : ""
                testResult = "✅ \(descriptor.name): \(s.mgdl) mg/dL \(s.trend.rawValue) (\(ageStr))\(staleNote)"
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        testResult = "⚠️ No reading from \(descriptor.name) yet. Check the credentials above, that the sensor is sharing/nearby, and that this is the selected source."
    }
}
