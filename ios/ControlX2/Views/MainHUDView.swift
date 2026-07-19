import SwiftUI

/// Loop-style main screen: glucose chart, status ring, HUD pills, and a bottom toolbar for
/// carb/bolus/connection actions. ControlX2 is a manual remote-bolus + status viewer.
struct MainHUDView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showBolus = false
    @State private var showPairing = false
    @State private var windowHours = 3
    private let windows = [3, 6, 12, 24]

    /// Auto-reconnect using the saved pairing when there's one and we're idle (launch or
    /// returning to the foreground — backgrounding drops the connection).
    private func autoReconnectIfNeeded() async {
        guard model.hasStoredPairing, model.snapshot.connection == .disconnected else { return }
        await model.connect()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        GlucoseChartView(readings: model.glucoseHistory, windowHours: windowHours)
                        Picker("Window", selection: $windowHours) {
                            ForEach(windows, id: \.self) { Text("\($0)h").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal)

                    StatusRingView(snapshot: model.snapshot)

                    if let u = model.snapshot.lastBolusUnits, let d = model.snapshot.lastBolusDate {
                        Text("Last bolus: \(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) { StatusPillsView(snapshot: model.snapshot) }
                        .padding(.horizontal)

                    if let err = model.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(LoopTheme.low).padding(.horizontal)
                    }
                    if let g = model.garminStatus {
                        Label(g, systemImage: "applewatch.radiowaves.left.and.right")
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("ControlX2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { connectionButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.setupGarmin?() } label: { Image(systemName: "applewatch.radiowaves.left.and.right") }
                        .accessibilityLabel("Set up Garmin remote")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showBolus = true } label: { Label("Bolus", systemImage: "drop.fill") }
                        .disabled(model.snapshot.connection != .connected)
                    Spacer()
                    Text("Bench PoC — saline only").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if model.snapshot.connection == .bolusing {
                        Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                            Label("Cancel", systemImage: "stop.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showBolus) { BolusEntryView(model: model) }
            .sheet(isPresented: $showPairing) { PairingSheet(model: model) { showPairing = false } }
            .onChange(of: model.openBolusRequested) { _, requested in
                if requested { showBolus = true; model.openBolusRequested = false }  // widget deep link
            }
            .task { await autoReconnectIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await autoReconnectIfNeeded() } }
            }
            .alert("Remote bolus request", isPresented: .constant(model.pendingRemoteBolus != nil)) {
                Button("Deliver \(String(format: "%.2f U", model.pendingRemoteBolus?.units ?? 0))", role: .destructive) {
                    Task { await model.confirmRemoteBolus() }
                }
                Button("Reject", role: .cancel) { model.rejectRemoteBolus() }
            } message: {
                Text("A remote requested \(String(format: "%.2f U", model.pendingRemoteBolus?.units ?? 0)) of SALINE. Confirm to deliver on the bench.")
            }
        }
    }

    @ViewBuilder private var connectionButton: some View {
        switch model.snapshot.connection {
        case .disconnected, .error:
            if model.hasStoredPairing {
                Menu("Connect") {
                    Button("Connect (saved pairing)") { Task { await model.connect() } }
                    Button("Re-pair with new code") { model.forgetPairing(); showPairing = true }
                }
            } else {
                Button("Connect") { showPairing = true }
            }
        case .connected, .bolusing:
            Button("Disconnect") { model.disconnect() }
        default:
            ProgressView()
        }
    }
}

/// Enter the pump's 6-digit pairing code, then connect + JPAKE-pair.
struct PairingSheet: View {
    @Bindable var model: AppModel
    let onDone: () -> Void
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Pump pairing code") {
                    TextField("6 digits", text: $code)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                }
                Section {
                    Button {
                        model.pairingCode = code
                        Task { await model.connect() }
                        onDone()
                    } label: {
                        HStack { Spacer(); Text("Connect"); Spacer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(code.count != 6)
                } footer: {
                    Text("On the pump: Options → Device Settings → Bluetooth → Pair Device. Unpair the official t:connect app first — only one connection at a time. Bench pump / saline only.")
                }
            }
            .navigationTitle("Connect to pump")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
        }
    }
}

#Preview {
    MainHUDView(model: AppModel(source: MockPumpDataSource()))
}
