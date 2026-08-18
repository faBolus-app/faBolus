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
    @State private var nsApiSecret = ""
    // Dexcom G5/G6/ONE (direct, passive "follow the Dexcom app")
    @State private var g6TransmitterID = ""

    /// E7: the currently-selected fallback source's display name (nil if none chosen yet), for the
    /// "Test <name>" button label and the empty-state guidance.
    private var selectedSourceName: String? {
        guard let id = GlucoseSourceRegistry.selectedId() else { return nil }
        return GlucoseSourceRegistry.descriptor(id: id)?.name ?? id
    }

    /// E7: which sources the "Test" button exercises — ONLY the currently-selected fallback source (the
    /// one the app will actually use), never the whole set. Empty when no fallback is chosen yet. Pure so
    /// the selected-only contract is unit-testable without the SwiftUI view.
    static func sourcesToTest(selectedId: String?) -> [String] {
        guard let id = selectedId, !id.isEmpty else { return [] }
        return [id]
    }

    // MARK: - Test flow (change 3, D-13 UX): determinate, observes the live production source

    /// Outcome of observing the selected source's live production probe (`AppModel.
    /// glucoseSourceProbe`) for the "Test" flow — DETERMINATE: the caller (`AppModel.startCgmTest`)
    /// polls elapsed time on a timer and re-evaluates, rather than an indeterminate spinner.
    /// `.success` when a reading is already buffered — an already-buffered reading always wins, even
    /// past the timeout, so a late poll tick can never downgrade a real result to a timeout. `.timeout`
    /// once the window has elapsed with nothing, OR immediately if the source reports a hard `.error`
    /// (nothing to wait for — surfaced right away regardless of elapsed). `.waiting` otherwise.
    enum CgmTestOutcome: Equatable {
        case waiting
        case success(GlucoseSample)
        case timeout(detail: String?)
    }

    /// The pure Test-flow decision (change 3, D-13 UX) — kept pure and unit-testable like
    /// `sourcesToTest` (`CgmTestFlowStateTests`). See `CgmTestOutcome` for the priority order.
    static func testOutcome(latest: GlucoseSample?, status: GlucoseSourceStatus,
                             elapsed: TimeInterval, timeout: TimeInterval) -> CgmTestOutcome {
        if let latest { return .success(latest) }
        if case let .error(msg) = status { return .timeout(detail: msg) }
        if elapsed >= timeout { return .timeout(detail: nil) }
        return .waiting
    }

    private func waitingHeadline() -> String {
        switch GlucoseSourceRegistry.selectedId() {
        case "dexcom-g6-ble", "dexcom-g7-ble":
            return "Waiting for the next Dexcom reading — up to ~5 min. You can leave this screen; we'll keep listening."
        default:
            return "Waiting for a reading from \(selectedSourceName ?? "the selected source"). You can leave this screen; we'll keep listening."
        }
    }

    private func successHeadline() -> String {
        switch GlucoseSourceRegistry.selectedId() {
        case "dexcom-g6-ble": return "✓ Received a reading from your G6"
        case "dexcom-g7-ble": return "✓ Received a reading from your G7"
        default: return "✓ Received a reading from \(selectedSourceName ?? "the selected source")"
        }
    }

    private func successDetail(_ sample: GlucoseSample) -> String {
        let age = Int(max(0, Date().timeIntervalSince(sample.date)))
        let ageStr = age < 60 ? "\(age)s ago" : "\(age / 60) min ago"
        let stale = GlucoseFreshness.isStale(sample.date) ? " · STALE" : ""
        // WR-03 gap closure (04-07): route through the display-unit funnel — reachable from mainline
        // Settings ("CGM credentials & testing"), not debug-gated.
        let bgUnit = AppSettings.shared.glucoseDisplayUnit
        let bgStr = "\(bgUnit.format(mgdl: sample.mgdl)) \(bgUnit == .mmol ? "mmol/L" : "mg/dL")"
        return "\(bgStr) \(sample.trend?.rawValue ?? "") · \(ageStr)\(stale)"
    }

    private func timeoutHeadline(elapsedSeconds: Int) -> String {
        let minutes = max(1, elapsedSeconds / 60)
        switch GlucoseSourceRegistry.selectedId() {
        case "dexcom-g6-ble", "dexcom-g7-ble":
            return "No reading yet after \(minutes) min — make sure the Dexcom app is running; try toggling its Bluetooth."
        default:
            return "No reading yet after \(minutes) min from \(selectedSourceName ?? "the selected source") — check the connection/credentials."
        }
    }

    private func elapsedLabel(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s elapsed" : "\(seconds / 60)m \(seconds % 60)s elapsed"
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
                SecureField("API secret (optional, for upload)", text: $nsApiSecret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Nightscout (any CGM)")
            } footer: {
                Text("A Nightscout site for reading (follower) and/or uploading. Token is optional if the site allows unauthenticated reads; the API secret is used for uploads. Turn uploading on under **Settings → CGM & failover → Nightscout upload**.")
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
                Text("Dexcom G5 / G6 / ONE — Read from Dexcom app (experimental)")
            } footer: {
                // D-03/D-05 (Plan 04): confident guided-setup copy, replacing the earlier hedging
                // framing that this document's "D-05 reliability re-check" section walked back
                // (09.20-RESEARCH.md — the re-check found no evidence for it). "Read from Dexcom
                // app" is the DEFAULT mode: reliable whenever its one hard precondition holds (the
                // official Dexcom app installed, paired, and running). The experimental / untested
                // marker stays (D-14) — the mechanism is confident, but on-device validation (D-13)
                // hasn't run yet.
                Text("This is the default **Read from Dexcom app** mode: faBolus reads your sensor passively, alongside the official Dexcom app — it never takes over the connection. Keep the official Dexcom app installed, paired, and running; without it there are no readings (that's when **Dexcom Share**, above, is the fallback). A sensor already set up in the Dexcom app works as-is: no re-pairing and no transmitter ID needed for a single sensor — but if anyone else nearby also wears a Dexcom (a sibling, a clinic waiting room, another household member), enter your transmitter ID above so faBolus reads YOUR sensor, not theirs. The first reading can take up to ~5 minutes — one Dexcom wake cycle — which is normal, not a failure. If nothing arrives after 5–10 minutes, toggle Bluetooth off then on inside the official Dexcom app. Experimental: untested until validated on-device.")
            }

            Section {
                Button {
                    save()
                    model.startCgmTest()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text(model.cgmTestInProgress ? "Testing…" : "Test \(selectedSourceName ?? "selected source")").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(model.cgmTestInProgress || selectedSourceName == nil)

                // Change 3 (D-13 UX): a DETERMINATE waiting state — a linear ProgressView with a
                // `value` (not the indeterminate spinner variant), an elapsed indicator, and explicit
                // SUCCESS/TIMEOUT terminal states. `model.cgmTestOutcome`/`cgmTestElapsedSeconds` are
                // AppModel-owned (not view @State), so this state SURVIVES navigating away and back.
                if let outcome = model.cgmTestOutcome {
                    switch outcome {
                    case .waiting:
                        VStack(alignment: .leading, spacing: 6) {
                            Text(waitingHeadline()).font(.subheadline)
                            ProgressView(value: model.cgmTestTimeoutSeconds > 0
                                         ? min(1, Double(model.cgmTestElapsedSeconds) / Double(model.cgmTestTimeoutSeconds)) : 0)
                            Text(elapsedLabel(seconds: model.cgmTestElapsedSeconds))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .success(let sample):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(successHeadline()).font(.subheadline)
                                Text(successDetail(sample)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    case .timeout(let detail):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(timeoutHeadline(elapsedSeconds: model.cgmTestElapsedSeconds)).font(.subheadline)
                                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if selectedSourceName == nil {
                    Text("Pick a fallback source above, then test it here. Credentials save automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Credentials save automatically (applied the next time the app launches, like the fallback selection itself). **Test** observes the fallback source that's already running in the background, so a reading it already has shows instantly. Direct-BLE Dexcom sources (G7/G6) wait up to ~5 minutes for the sensor's next wake cycle — you can leave this screen; it keeps listening.")
            }
        }
        .navigationTitle("CGM credentials & testing")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        // E7: no Save button — leaving this sub-view persists whatever was entered (and Test / "read
        // transmitter ID" also save immediately), so credentials are never lost to a missed tap.
        .onDisappear(perform: save)
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
        nsApiSecret = CredentialStore.get(account: "nightscout.apisecret") ?? ""
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
        CredentialStore.set(trimmed(nsApiSecret), account: "nightscout.apisecret")
        GlucoseSourceConfig.set(trimmed(g6TransmitterID)?.uppercased(), "dexcomg6.transmitterId")
    }

}
