import SwiftUI
import faBolusCore

/// Dashboard tab: modern glucose chart + status ring + HUD pills, then a scrollable details
/// section with everything sourced from the pump. Connection lives in the toolbar.
struct DashboardView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var windowHours = 3
    private let windows = [3, 6, 12, 24]

    var body: some View {
        @Bindable var settings = settings   // local @Bindable for binding projection
        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Above the fold: glucose ring + the four status pills + the chart. Connection
                    // and Garmin setup live in the Settings tab now (not the toolbar).
                    StatusRingView(snapshot: model.snapshot)

                    AlertsBannerView(model: model)

                    if model.snapshot.connection == .bolusing {
                        Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                            Label("Cancel bolus", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal)
                    }

                    StatusPillsView(snapshot: model.snapshot).padding(.horizontal)

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

                    // Scroll target: everything else from the pump.
                    PumpDetailsCard(snapshot: model.snapshot).padding(.horizontal)

                    if let err = model.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(AppTheme.low).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("faBolus")
            .navigationBarTitleDisplayMode(.inline)
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
                    Text("On the pump: Options → Device Settings → Bluetooth → Pair Device. Unpair the official t:connect app first — only one connection at a time.")
                }
            }
            .navigationTitle("Connect to pump")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
        }
    }
}
