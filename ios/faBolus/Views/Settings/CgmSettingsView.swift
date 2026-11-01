import GlucoseSources
import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// The backup CGM: which source, its account or transmitter, a test, and its status. One source runs at a
/// time; it supplies the glucose shown only while the pump's own is stale or missing.
struct CgmSettingsView: View {
    @Bindable var model: AppModel
    @State private var selection = ""
    @State private var username = ""
    @State private var password = ""
    @State private var region = ShareRegion.us
    @State private var transmitterID = ""
    @State private var saveMessage: String?
    @State private var test = CgmTestCoordinator()
    @State private var testState: CgmTestCoordinator.State?

    private var registry: GlucoseSourceRegistry { model.glucoseSources }

    var body: some View {
        Form {
            Section {
                Picker("Backup CGM", selection: $selection) {
                    Text("None (pump only)").tag("")
                    ForEach(registry.descriptors) { Text($0.name).tag($0.id) }
                }
                .onChange(of: selection) { _, id in
                    guard id != (model.backupSourceID ?? "") else { return }
                    Task { await model.selectBackupSource(id.isEmpty ? nil : id) }
                }
                if let status = model.backup?.status { statusRow(status) }
            } footer: {
                Text(
                    "An independent glucose feed used when the pump's reading is stale or missing. Old readings are shown marked, never as current."
                )
            }
            switch selection {
            case GlucoseSourceRegistry.shareID: shareSection
            case GlucoseSourceRegistry.g6ID: g6Section
            case GlucoseSourceRegistry.g7ID: g7Section
            default: EmptyView()
            }
            if !selection.isEmpty { testSection }
        }
        .navigationTitle("CGM & backup")
        .onAppear {
            selection = model.backupSourceID ?? registry.selectedID ?? ""
            username = registry.account.username ?? ""
            region = registry.account.region
            transmitterID = registry.settings.g6TransmitterID ?? ""
            test.probe = { [model] in await model.probeBackupSource() }
            test.onStateChanged = { testState = $0 }
        }
    }

    private func statusRow(_ status: GlucoseSourceStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .idle: return ("Not started", .secondary)
            case .needsSetup: return ("Needs setup", .orange)
            case .searching: return ("Connecting…", .secondary)
            case .connected: return ("Receiving readings", AppTheme.inRange)
            case .stale: return ("Connected, no recent reading", .orange)
            case .unavailable(let problem): return (problem.message, AppTheme.low)
            }
        }()
        return LabeledContent("Status") { Text(text).foregroundStyle(color).multilineTextAlignment(.trailing) }
    }

    private var shareSection: some View {
        Section {
            TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(registry.account.hasPassword ? "Password (saved)" : "Password", text: $password)
                .textContentType(.password)
            Picker("Region", selection: $region) {
                Text("US").tag(ShareRegion.us)
                Text("Outside US").tag(ShareRegion.ous)
                Text("Asia-Pacific (Japan)").tag(ShareRegion.apac)
            }
            Button("Save and check") {
                Task {
                    do {
                        try await model.saveShareAccount(
                            username: username.trimmingCharacters(in: .whitespaces),
                            password: password.isEmpty ? nil : password, region: region)
                        password = ""
                        saveMessage = "Saved."
                    } catch {
                        saveMessage = "Not saved: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
            if let saveMessage { Text(saveMessage).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Dexcom Share")
        } footer: {
            Text(
                "The account that shares your readings in the Dexcom app (Share must be on). Leave the password blank to keep the saved one."
            )
        }
    }

    private var g6Section: some View {
        Section {
            TextField("Transmitter ID (optional)", text: $transmitterID)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Save transmitter ID") {
                Task {
                    do {
                        try await model.setG6TransmitterID(transmitterID)
                        saveMessage = transmitterID.isEmpty ? "Using the pump's transmitter ID." : "Saved."
                    } catch {
                        saveMessage = "That isn't a G6 transmitter ID (6 letters and numbers)."
                    }
                }
            }
            if let saveMessage { Text(saveMessage).font(.footnote).foregroundStyle(.secondary) }
            if let fromPump = model.pump.cgmHardwareInfo?.value, transmitterID.isEmpty {
                LabeledContent("From the pump", value: fromPump)
            }
        } header: {
            Text("Dexcom G6")
        } footer: {
            Text(
                "Keep the Dexcom app installed, paired with the transmitter and running: faBolus reads alongside it and never pairs or calibrates. The transmitter ID is printed on the transmitter and shown in the Dexcom app; with none typed, faBolus uses the one the pump reports. Change it when the transmitter changes. No Bluetooth pairing prompt should appear; if one does, please report it."
            )
        }
    }

    private var g7Section: some View {
        Section {
        } header: {
            Text("Dexcom G7")
        } footer: {
            Text(
                "Keep the Dexcom app installed, paired with the sensor and running: faBolus reads alongside it and never pairs or calibrates. There's nothing to enter. After a sensor change, faBolus finds the new sensor by itself once the Dexcom app has paired it. No Bluetooth pairing prompt should appear; if one does, please report it."
            )
        }
    }

    private var testSection: some View {
        Section {
            Button(testState?.inProgress == true ? "Testing…" : "Test") { Task { await test.start() } }
                .disabled(testState?.inProgress == true)
            if let testState, let outcome = testState.outcome {
                switch outcome {
                case .waiting:
                    Text("Waiting for a reading… \(testState.elapsedSeconds) s").font(.subheadline)
                case .success(let sample):
                    Label(
                        "Got \(model.settings.glucoseUnit.format(mgdl: sample.mgdl)) mg/dL, measured \(sample.date.formatted(date: .omitted, time: .shortened))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(AppTheme.inRange)
                case .timeout(let detail):
                    Label(detail ?? "No reading yet.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(
                        .orange)
                }
            }
        } footer: {
            Text("Checks that the running source can get a reading.")
        }
    }
}
