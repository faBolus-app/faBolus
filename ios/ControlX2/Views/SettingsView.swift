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

    /// The Siri phrases (mirror `ControlX2Shortcuts`), shown for discoverability.
    static let siriPhrases = [
        "What's my glucose in ControlX2",
        "Insulin on board in ControlX2",
        "Pump status in ControlX2",
        "Last bolus in ControlX2",
    ]

    private func fmtU(_ v: Double) -> String {
        v < 0.1 ? String(format: "%.2f U", v) : (v < 1 ? String(format: "%.1f U", v) : String(format: "%.0f U", v))
    }
}

/// Reorder the Garmin remote's swipe screens and choose which opens first. Drag to reorder (Edit),
/// then pick the default. The new layout is pushed to the watch on its next status update.
struct GarminScreensView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Opens first", selection: $settings.garminDefaultScreen) {
                    ForEach(settings.garminScreenOrder, id: \.self) { id in
                        Text(AppSettings.garminScreenLabel(id)).tag(id)
                    }
                }
            } footer: {
                Text("The screen shown when the Garmin app launches.")
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
            } header: {
                Text("Swipe order (top → bottom)")
            } footer: {
                Text("Swiping up on the watch moves down this list; swiping down moves up.")
            }
        }
        .navigationTitle("Garmin Screens")
        .toolbar { EditButton() }
    }
}
