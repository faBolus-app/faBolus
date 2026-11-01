import PhoneApp
import PumpSession
import SwiftUI
import faBolusCore

/// Pairing: the phone looks for pumps in pairing mode, the user picks theirs and types the code it shows.
struct PairingSheet: View {
    @Bindable var model: AppModel
    let onDone: () -> Void
    @State private var code = ""
    @State private var selected: AppModel.FoundPump?
    @State private var pairing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.pumpsFound.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for pumps in pairing mode…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.pumpsFound) { pump in
                        Button {
                            selected = pump
                        } label: {
                            HStack {
                                Text(pump.name ?? "Unnamed pump")
                                Spacer()
                                if selected == pump { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .disabled(pump.model != .tslimX2)
                    }
                } header: {
                    Text("Pump")
                } footer: {
                    if model.pumpsFound.contains(where: { $0.model == .mobi }) {
                        Text("faBolus doesn't connect to a Mobi yet.")
                    }
                }
                Section {
                    TextField("6-digit or 16-character code", text: $code)
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.title2.monospaced())
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text(
                        "On the pump: Options → Device Settings → Bluetooth → Pair Device. Unpair the official t:connect app first — only one connection at a time.\n\nMost pumps show a 6-digit code. Older pumps (firmware before v7.7) show a longer 16-character code with letters and numbers — enter it exactly as shown (it is case-sensitive); faBolus pairs either way automatically."
                    )
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button {
                        pair()
                    } label: {
                        HStack {
                            Spacer()
                            if pairing { ProgressView() } else { Text("Pair") }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || !PumpPairingCode.isValid(code) || pairing)
                }
            }
            .navigationTitle("Connect to pump")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
            .task { await model.scanForPumps() }
            // Leaving without pairing (Cancel, a swipe) brings the paired pump back.
            .onDisappear { Task { await model.endPairingScan() } }
            .onChange(of: model.pumpsFound) { _, found in
                if selected == nil, found.count == 1, found[0].model == .tslimX2 { selected = found[0] }
            }
            .onChange(of: model.linkFailure) { _, failure in
                if let failure {
                    error = PumpMessages.text(failure)
                    pairing = false
                }
            }
            .onChange(of: model.pump.link) { _, link in
                if link == .connected, pairing { onDone() }
            }
        }
    }

    private func pair() {
        guard let selected else { return }
        error = nil
        pairing = true
        Task {
            do {
                try await model.pair(selected, code: code.trimmingCharacters(in: .whitespaces))
            } catch let refusal as PumpSession.PairingRefusal {
                self.error = Self.text(refusal)
                pairing = false
            } catch {
                pairing = false
            }
        }
    }

    static func text(_ refusal: PumpSession.PairingRefusal) -> String {
        switch refusal {
        case .invalidCode: return "That isn't a pairing code. Enter the 6-digit or 16-character code the pump shows."
        case .mobiNotSupported: return "faBolus doesn't connect to a Mobi yet."
        case .unknownModel: return "faBolus connects only to a t:slim X2."
        }
    }
}

/// Shown once at first launch while no pump is paired. Skippable; the dashboard keeps offering pairing.
struct ConnectPumpOnboardingView: View {
    @Bindable var model: AppModel
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 56)).foregroundStyle(
                        .tint
                    )
                    .accessibilityHidden(true)
                    Text("Connect your pump").font(.title.bold())
                    Text(
                        "faBolus needs a pump connection to show your glucose and let you give a bolus. Connect now, or skip and connect later from the dashboard."
                    )
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text(RegulatoryCopy.firstRun).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(
                        .center)
                    Button {
                        showPairing = true
                    } label: {
                        Text("Connect a pump").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Skip for now") { model.settings.hasCompletedOnboarding = true }.foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                    VStack(spacing: 8) {
                        Text("Optional: a backup glucose feed").font(.headline)
                        Text(
                            "faBolus can read Dexcom Share, or a G6 or G7 directly alongside the Dexcom app, as a backup. It's used only while the pump's own reading is stale."
                        )
                        .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        NavigationLink("Set up backup CGM") { CgmSettingsView(model: model) }.buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet(model: model) {
                showPairing = false
                if model.pairing != nil { model.settings.hasCompletedOnboarding = true }
            }
        }
    }
}
