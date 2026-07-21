import SwiftUI
import faBolusCore

/// Enter the cloud-follower credentials for the CGM failover sources. Non-secret fields persist to
/// UserDefaults (`GlucoseSourceConfig`); passwords/tokens go to the Keychain (`CredentialStore`).
/// Applied on the next launch (like the source/backend selection). Sensitive fields use SecureField.
struct CgmCredentialsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var readingTxId = false
    @State private var readTxIdError: String?

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

    @State private var testing = false
    @State private var results: [SourceResult] = []
    @State private var savedNote = false

    /// One method's save-&-test outcome, shown in the results list.
    private struct SourceResult: Identifiable {
        enum Status { case ok, warn, fail }
        let id: String
        let name: String
        let status: Status
        let detail: String
        var symbol: String { status == .ok ? "checkmark.circle.fill" : status == .warn ? "exclamationmark.triangle.fill" : "xmark.circle.fill" }
        var color: Color { status == .ok ? .green : status == .warn ? .orange : .red }
    }

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
                Button {
                    Task {
                        readingTxId = true; readTxIdError = nil
                        if let id = await model.readG6TransmitterId() {
                            g6TransmitterID = id; save()
                        } else {
                            readTxIdError = "Couldn't read the transmitter ID — connect to the pump first (it reports the paired G6 transmitter)."
                        }
                        readingTxId = false
                    }
                } label: {
                    HStack {
                        Label("Read transmitter ID from pump", systemImage: "arrow.down.circle")
                        if readingTxId { Spacer(); ProgressView() }
                    }
                }
                .disabled(readingTxId)
                if let e = readTxIdError { Text(e).font(.caption).foregroundStyle(.orange) }
            } header: {
                Text("Dexcom G5 / G6 / ONE (direct — experimental)")
            } footer: {
                Text("Experimental and often unreliable: a G6 only talks to its authenticated app and allows few Bluetooth connections, so this passive read may never connect. For a dependable backup, prefer **Dexcom Share** (above) or **xDrip4iOS via the App Group**. Keep the official Dexcom app running — faBolus reads passively alongside it. The transmitter ID just helps pick the right sensor if several are nearby; no login needed. “Read transmitter ID from pump” fills it from the connected pump.")
            }

            Section {
                Button {
                    Task { await saveAndTestAll() }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text(testing ? "Testing…" : "Save & test").fontWeight(.semibold)
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing)

                ForEach(results) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: r.symbol).foregroundStyle(r.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.subheadline)
                            Text(r.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if savedNote && results.isEmpty {
                    Text("Saved. Enter credentials for a source above to test it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Saves all credentials, then tries to pull a live reading from **every** source you've entered credentials for — so you can see which ones work. Then pick the one to use in Settings → CGM source.")
            }
        }
        .navigationTitle("CGM credentials")
        .navigationBarTitleDisplayMode(.inline)
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

    private func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Save all credentials, then test **every** source that has credentials entered: build it, start
    /// it, and poll ~7 s for a live reading, appending a per-method result as each finishes. Sources
    /// with no credentials (G7 BLE, HealthKit, xDrip App Group) aren't cloud-testable and are skipped.
    @MainActor private func saveAndTestAll() async {
        save()
        testing = true; savedNote = true; results = []
        defer { testing = false }
        let toTest: [String] = [
            (filled(libreUser) && filled(librePass)) ? "librelinkup" : nil,
            (filled(shareUser) && filled(sharePass)) ? "dexcom-share" : nil,
            filled(nsURL) ? "nightscout" : nil,
            // Direct G6 is passive/experimental and needs no credentials (the transmitter ID is
            // optional), so test it whenever it's the selected source — don't gate on the tx id.
            (GlucoseSourceRegistry.selectedId() == "dexcom-g6-ble" || filled(g6TransmitterID)) ? "dexcom-g6-ble" : nil,
        ].compactMap { $0 }

        for id in toTest {
            let name = GlucoseSourceRegistry.descriptor(id: id)?.name ?? id
            guard let source = GlucoseSourceRegistry.make(id: id) else {
                results.append(SourceResult(id: id, name: name, status: .fail, detail: "couldn't build source"))
                continue
            }
            await source.start()
            var result = SourceResult(id: id, name: name, status: .warn,
                                      detail: "no reading yet — check credentials / that the sensor is sharing")
            // Direct BLE (G6) can take longer to see the first message and a G6 only emits every
            // ~5 min, so give it a longer window; cloud sources answer fast.
            let attempts = (id == "dexcom-g6-ble") ? 30 : 8
            for _ in 0..<attempts {
                if let s = source.latest {
                    let age = Int(max(0, Date().timeIntervalSince(s.date)))
                    let ageStr = age < 60 ? "\(age)s ago" : "\(age / 60) min ago"
                    let stale = GlucoseFreshness.isStale(s.date) ? " · STALE" : ""
                    result = SourceResult(id: id, name: name, status: .ok,
                                          detail: "\(s.mgdl) mg/dL \(s.trend.rawValue) · \(ageStr)\(stale)")
                    break
                }
                // Surface a real connection error instead of a generic "no reading" warning.
                if case let .error(msg) = source.status {
                    result = SourceResult(id: id, name: name, status: .fail, detail: msg)
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            results.append(result)
            source.stop()
        }
    }
}
