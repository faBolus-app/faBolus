import SwiftUI

/// Settings tab: bolus defaults + increments (shared with the remotes), chart axes, and pump
/// pairing management.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var showPairing = false

    var body: some View {
        @Bindable var settings = settings   // local @Bindable for binding projection
        NavigationStack {
            Form {
                Section {
                    Picker("Default mode", selection: $settings.defaultBolusMode) {
                        Text("Carbs").tag(BolusMode.carbs)
                        Text("Units").tag(BolusMode.units)
                    }
                } header: {
                    Text("Bolus entry")
                } footer: {
                    Text("Default entry mode for the iPhone, the widget, and the remotes.")
                }

                Section {
                    Picker("Bolus increment", selection: $settings.bolusIncrement) {
                        ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                    }
                    Picker("Carb increment", selection: $settings.carbIncrement) {
                        ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                    }
                } header: {
                    Text("iPhone increments")
                } footer: {
                    Text("Steps for the iPhone bolus screen and the Home-Screen widget.")
                }

                Section {
                    Picker("Bolus increment", selection: $settings.watchBolusIncrement) {
                        ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                    }
                    Picker("Carb increment", selection: $settings.watchCarbIncrement) {
                        ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                    }
                } header: {
                    Text("Watch & Garmin increments")
                } footer: {
                    Text("Steps for the Apple Watch and Garmin bolus screens (independent of the iPhone).")
                }

                Section("Chart") {
                    Toggle("Show glucose axis", isOn: $settings.showGlucoseAxis)
                    Toggle("Show insulin (IOB) axis", isOn: $settings.showIOBAxis)
                }

                Section {
                    NavigationLink {
                        GarminScreensView(settings: settings)
                    } label: {
                        LabeledContent("Screen order",
                                       value: AppSettings.garminScreenLabel(settings.garminDefaultScreen).components(separatedBy: " (").first ?? settings.garminDefaultScreen)
                    }
                } header: {
                    Text("Garmin remote")
                } footer: {
                    Text("Reorder the Garmin app's swipe screens and pick which one opens first. Applied on the watch's next update.")
                }

                Section {
                    ForEach(SettingsView.siriPhrases, id: \.self) { p in
                        Label("“\(p)”", systemImage: "mic.fill").font(.callout)
                    }
                } header: {
                    Text("Siri (read-only)")
                } footer: {
                    Text("These work automatically — no setup needed. Say “Hey Siri” then a phrase, or add them in the Shortcuts app. Siri never delivers a bolus.")
                }

                Section("Pump") {
                    LabeledContent("Status", value: model.snapshot.connection.rawValue)
                    connectionControls
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
                    Text("faBolus is an independent, open-source project, in development for experimental use. Not FDA-cleared. Not affiliated with Tandem Diabetes Care or Dexcom.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPairing) { PairingSheet(model: model) { showPairing = false } }
        }
    }

    /// Connect / disconnect / re-pair — moved here from the Dashboard toolbar.
    @ViewBuilder private var connectionControls: some View {
        switch model.snapshot.connection {
        case .disconnected, .error:
            if model.hasStoredPairing {
                Button("Connect (saved pairing)") { Task { await model.connect() } }
                Button("Re-pair with new code") { model.forgetPairing(); showPairing = true }
            } else {
                Button("Connect") { showPairing = true }
            }
        case .connected, .bolusing:
            Button("Disconnect", role: .destructive) { model.disconnect() }
        default:
            HStack { Text("Connecting…").foregroundStyle(.secondary); Spacer(); ProgressView() }
        }
    }

    /// The Siri phrases (mirror `FaBolusShortcuts`), shown for discoverability.
    static let siriPhrases = [
        "What's my glucose in Control X2",
        "Insulin on board in Control X2",
        "Pump status in Control X2",
        "Any alerts in Control X2",
        "Last bolus in Control X2",
    ]

    private func fmtU(_ v: Double) -> String {
        v < 0.1 ? String(format: "%.2f U", v) : (v < 1 ? String(format: "%.1f U", v) : String(format: "%.0f U", v))
    }
}

/// Choose which Garmin screens appear, their swipe order, and which opens first. Toggle screens
/// on/off, drag to reorder (Edit), and pick the default. Pushed to the watch on its next status update.
struct GarminScreensView: View {
    @Bindable var settings: AppSettings

    // Known screens not currently shown (available to add back).
    private var hidden: [String] {
        AppSettings.garminScreens.filter { !settings.garminScreenOrder.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Opens first", selection: $settings.garminDefaultScreen) {
                    ForEach(settings.garminScreenOrder, id: \.self) { id in
                        Text(AppSettings.garminScreenLabel(id)).tag(id)
                    }
                }
            } footer: {
                Text("The screen shown when the Garmin app launches (from the shown screens).")
            }

            Section {
                ForEach(settings.garminScreenOrder, id: \.self) { id in
                    Label(AppSettings.garminScreenLabel(id),
                          systemImage: id == settings.garminDefaultScreen ? "star.fill" : "line.3.horizontal")
                        .foregroundStyle(id == settings.garminDefaultScreen ? Color.accentColor : .primary)
                }
                .onMove { from, to in
                    settings.garminScreenOrder.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { idx in hideScreens(idx) }
            } header: {
                Text("Shown on watch (top → bottom)")
            } footer: {
                Text("Swiping up on the watch moves down this list. Swipe a row left to hide it — at least one screen must stay shown.")
            }

            if !hidden.isEmpty {
                Section {
                    ForEach(hidden, id: \.self) { id in
                        Button {
                            settings.garminScreenOrder = settings.garminScreenOrder + [id]
                        } label: {
                            Label(AppSettings.garminScreenLabel(id), systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Hidden")
                } footer: {
                    Text("Tap to show a screen on the watch.")
                }
            }
        }
        .navigationTitle("Garmin Screens")
        .toolbar { EditButton() }
    }

    // Hide the selected shown-screens, keeping at least one and a valid default.
    private func hideScreens(_ idx: IndexSet) {
        guard settings.garminScreenOrder.count - idx.count >= 1 else { return }
        var order = settings.garminScreenOrder
        order.remove(atOffsets: idx)
        settings.garminScreenOrder = order
        if !order.contains(settings.garminDefaultScreen) {
            settings.garminDefaultScreen = order.first ?? "glance"
        }
    }
}
