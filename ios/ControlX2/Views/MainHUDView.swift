import SwiftUI

/// Dashboard tab: Loop-style glucose chart + status ring + HUD pills, then a scrollable details
/// section with everything sourced from the pump. Connection lives in the toolbar.
struct DashboardView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var showPairing = false
    @State private var windowHours = 3
    private let windows = [3, 6, 12, 24]

    var body: some View {
        @Bindable var settings = settings   // local @Bindable for binding projection
        return NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        GlucoseChartView(readings: model.glucoseHistory, iob: model.iobHistory,
                                         boluses: model.bolusMarkers, windowHours: windowHours,
                                         showGlucose: settings.showGlucoseAxis, showIOB: settings.showIOBAxis)
                        Picker("Window", selection: $windowHours) {
                            ForEach(windows, id: \.self) { Text("\($0)h").tag($0) }
                        }.pickerStyle(.segmented)
                        HStack(spacing: 16) {
                            Toggle("Glucose", isOn: $settings.showGlucoseAxis)
                            Toggle("IOB", isOn: $settings.showIOBAxis)
                        }.font(.caption).toggleStyle(.button).controlSize(.small)
                    }
                    .padding(.horizontal)

                    AlertsBannerView(model: model)
                    StatusRingView(snapshot: model.snapshot)

                    if model.snapshot.connection == .bolusing {
                        Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                            Label("Cancel bolus", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal)
                    }

                    VStack(spacing: 10) { StatusPillsView(snapshot: model.snapshot) }.padding(.horizontal)

                    PumpDetailsCard(snapshot: model.snapshot).padding(.horizontal)

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
            }
            .sheet(isPresented: $showPairing) { PairingSheet(model: model) { showPairing = false } }
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

/// Card listing everything sourced from the pump (scroll target for "more details").
struct PumpDetailsCard: View {
    let snapshot: PumpSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Active insulin (IOB)", String(format: "%.2f U", snapshot.iobUnits))
            row("Reservoir", "\(Int(snapshot.reservoirUnits)) U")
            row("Pump battery", "\(snapshot.batteryPercent)%")
            row("CGM", snapshot.cgmActive ? "Active" : "Inactive")
            if let u = snapshot.lastBolusUnits, let d = snapshot.lastBolusDate {
                row("Last bolus", "\(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .named)))")
            }
            row("Carb ratio", snapshot.carbRatio > 0 ? String(format: "%.0f g/U", snapshot.carbRatio) : "—")
            row("Correction factor (ISF)", snapshot.isf > 0 ? "\(snapshot.isf) mg/dL/U" : "—")
            row("Target glucose", snapshot.targetBg > 0 ? "\(snapshot.targetBg) mg/dL" : "—")
            row("Max bolus", String(format: "%.1f U", snapshot.maxBolusUnits), last: true)
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func row(_ title: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 10)
        if !last { Divider().padding(.leading, 14) }
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
                        .keyboardType(.numberPad).font(.title2.monospacedDigit())
                }
                Section {
                    Button {
                        model.pairingCode = code
                        Task { await model.connect() }
                        onDone()
                    } label: { HStack { Spacer(); Text("Connect"); Spacer() } }
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
