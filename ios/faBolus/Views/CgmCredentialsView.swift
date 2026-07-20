import SwiftUI

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

    @State private var saved = false

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

            if saved {
                Label("Saved — reopen the app to apply.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.footnote)
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
    }
}
