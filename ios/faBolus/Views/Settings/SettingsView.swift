import PhoneApp
import SwiftUI
import faBolusCore

/// Settings, by category.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    link("Pump", "cross.case.fill") { PumpSettingsView(model: model) }
                    link("Bolus & entry", "syringe.fill") { BolusSettingsView(settings: model.settings) }
                    link("CGM & backup", "sensor.tag.radiowaves.forward.fill") { CgmSettingsView(model: model) }
                    link("Freshness", "clock.badge.exclamationmark") { FreshnessSettingsView(settings: model.settings) }
                    link("Notifications", "bell.and.waves.left.and.right") { NotificationSettingsView(model: model) }
                }
                Section {
                    link("Display & chart", "chart.xyaxis.line") { DisplaySettingsView(settings: model.settings) }
                    link("Live Activity", "platter.filled.bottom.iphone") {
                        LiveActivitySettingsView(settings: model.settings)
                    }
                    link("Watch", "applewatch.radiowaves.left.and.right") { RemotesSettingsView(model: model) }
                }
                Section {
                    link("Safety", "lock.shield") { SafetySettingsView(settings: model.settings) }
                    link("Privacy & data", "hand.raised") { PrivacyDataView(model: model) }
                    link("About & help", "info.circle") { AboutSettingsView(model: model) }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func link<D: View>(_ title: String, _ icon: String, @ViewBuilder _ destination: () -> D) -> some View {
        NavigationLink(destination: destination()) { Label(title, systemImage: icon) }
    }
}

func unitsText(_ u: Double) -> String { u < 0.1 ? String(format: "%.2f U", u) : String(format: "%g U", u) }

struct SafetySettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Read-only mode", isOn: $settings.phoneReadOnly)
            } footer: {
                Text(
                    "This phone shows the pump and CGM but can't bolus: the Bolus tab is hidden. Cancelling a bolus and clearing pump alerts still work. The watch has its own switch under Watch."
                )
            }
        }
        .navigationTitle("Safety")
    }
}

struct BolusSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Default mode", selection: $settings.defaultBolusMode) {
                    Text("Carbs").tag(BolusEntryMode.carbs)
                    Text("Units").tag(BolusEntryMode.units)
                }
            } header: {
                Text("Bolus entry")
            }
            Section {
                Picker("Unit increment", selection: $settings.bolusIncrement) {
                    ForEach(AppSettings.bolusIncrements, id: \.self) { Text(unitsText($0)).tag($0) }
                }
                Picker("Carb increment", selection: $settings.carbIncrement) {
                    ForEach(AppSettings.carbIncrements, id: \.self) { Text("\($0) g").tag($0) }
                }
            } header: {
                Text("Increments")
            } footer: {
                Text("The steps of the bolus screen, on the phone and the watch.")
            }
            Section {
                Toggle("Show the calculation", isOn: $settings.showBolusReasoning)
            } footer: {
                Text("A breakdown under the suggested dose: carbs, correction and active insulin.")
            }
        }
        .navigationTitle("Bolus & entry")
    }
}

/// The one set of freshness windows: the phone, the watch, the widgets and the Live Activity all use it.
struct FreshnessSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Mark stale after", selection: $settings.glucoseStaleMinutes) {
                    ForEach(AppSettings.glucoseStaleOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Then hide after", selection: $settings.glucoseHideDelayMinutes) {
                    ForEach(AppSettings.glucoseHideDelayOptions, id: \.self) { Text(hideLabel($0)).tag($0) }
                }
            } header: {
                Text("Glucose")
            } footer: {
                Text(
                    "A reading older than this is shown greyed and never fills a correction. After the hide delay it shows as “—”. Staleness counts from when the reading was measured."
                )
            }
            Section {
                Picker("Mark stale after", selection: $settings.pumpStatusStaleMinutes) {
                    ForEach(AppSettings.pumpStatusStaleOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: {
                Text("Reservoir, battery, basal, Control-IQ")
            } footer: {
                Text("Older than this, they show as “—”.")
            }
            Section {
                LabeledContent("Active insulin", value: "5 min")
                LabeledContent("Bolus calculator settings", value: "15 min")
            } footer: {
                Text(
                    "These guard doses and can't be changed. These windows apply on the phone, the watch, the widgets and the Live Activity alike."
                )
            }
        }
        .navigationTitle("Freshness")
    }

    private func hideLabel(_ minutes: Int?) -> String {
        switch minutes {
        case .none: return "Never"
        case .some(0): return "Right away"
        case .some(let m): return "\(m) min later"
        }
    }
}

struct DisplaySettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Chart") {
                Toggle("Show glucose", isOn: $settings.showGlucoseAxis)
                Toggle("Show insulin (IOB) line", isOn: $settings.showIOBAxis)
                Toggle("Show bolus bars", isOn: $settings.showBolusBars)
                Picker("Plot ceiling", selection: $settings.glucosePlotCeiling) {
                    ForEach(GlucosePlotScale.ceilingOptions, id: \.self) {
                        Text(GlucosePlotScale.boundLabel($0, unit: settings.glucoseUnit)).tag($0)
                    }
                }
                Picker("Plot floor", selection: $settings.glucosePlotFloor) {
                    ForEach(GlucosePlotScale.floorOptions, id: \.self) {
                        Text(GlucosePlotScale.boundLabel($0, unit: settings.glucoseUnit)).tag($0)
                    }
                }
                Toggle("Show unit labels", isOn: $settings.showGlucoseUnitLabels)
            }
            Section {
                Toggle("Show statistics card", isOn: $settings.showStats)
            } footer: {
                Text("Time in range, average, GMI and variability over the last day. Off by default.")
            }
            Section {
                NavigationLink {
                    CustomizeListView(
                        title: "Details", allIDs: DetailsField.allIDs,
                        label: { DetailsField(rawValue: $0)?.label ?? $0 }, order: $settings.detailsOrder,
                        footer:
                            "Rows on the dashboard's Details card. “Last auto-correction” shows once the pump's history has one."
                    )
                } label: {
                    LabeledContent("Details rows", value: "\(settings.detailsOrder.count) shown")
                }
                NavigationLink {
                    CustomizeListView(
                        title: "Pills", allIDs: StatusPill.allIDs, label: { StatusPill(rawValue: $0)?.label ?? $0 },
                        order: $settings.pillsOrder, footer: "Status pills on the dashboard.")
                } label: {
                    LabeledContent("Dashboard pills", value: "\(settings.pillsOrder.count) shown")
                }
            } header: {
                Text("Customize")
            }
        }
        .navigationTitle("Display & chart")
    }
}

/// Reorder and hide a list of items; at least one stays.
struct CustomizeListView: View {
    let title: String
    let allIDs: [String]
    let label: (String) -> String
    @Binding var order: [String]
    let footer: String

    var body: some View {
        List {
            Section {
                ForEach(order, id: \.self) { Text(label($0)) }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        guard order.count > offsets.count else { return }
                        order.remove(atOffsets: offsets)
                    }
            } header: {
                Text("Shown")
            } footer: {
                Text(footer + " Drag to reorder, swipe to hide.")
            }
            let hidden = allIDs.filter { !order.contains($0) }
            if !hidden.isEmpty {
                Section("Hidden") {
                    ForEach(hidden, id: \.self) { id in
                        Button {
                            order.append(id)
                        } label: {
                            Label(label(id), systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(title)
    }
}
