import SwiftUI

/// Settings tab: bolus defaults + increments (shared with the remotes), chart axes, and pump
/// pairing management.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared

    var body: some View {
        @Bindable var settings = settings   // local @Bindable for binding projection
        NavigationStack {
            Form {
                Section {
                    Picker("Default mode", selection: $settings.defaultBolusMode) {
                        Text("Carbs").tag(BolusMode.carbs)
                        Text("Units").tag(BolusMode.units)
                    }
                    Picker("Bolus increment", selection: $settings.bolusIncrement) {
                        ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                    }
                    Picker("Carb increment", selection: $settings.carbIncrement) {
                        ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                    }
                } header: {
                    Text("Bolus entry")
                } footer: {
                    Text("Applies to the iPhone, Apple Watch, and Garmin bolus screens.")
                }

                Section("Chart") {
                    Toggle("Show glucose axis", isOn: $settings.showGlucoseAxis)
                    Toggle("Show insulin (IOB) axis", isOn: $settings.showIOBAxis)
                }

                Section("Pump") {
                    LabeledContent("Status", value: model.snapshot.connection.rawValue)
                    if model.hasStoredPairing {
                        Button("Forget pairing", role: .destructive) { model.forgetPairing() }
                    }
                    Button { model.setupGarmin?() } label: {
                        Label("Set up Garmin remote", systemImage: "applewatch.radiowaves.left.and.right")
                    }
                }

                Section {
                    if let g = model.garminStatus {
                        Text(g).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("ControlX2 — independent bench proof-of-concept. Saline only, never on a body.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func fmtU(_ v: Double) -> String {
        v < 0.1 ? String(format: "%.2f U", v) : (v < 1 ? String(format: "%.1f U", v) : String(format: "%.0f U", v))
    }
}
