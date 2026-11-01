import PhoneApp
import SwiftUI
import faBolusCore

/// The Garmin watch: what it may do, its layout, and the watch link's state. Everything here reaches the
/// watch through the config message the next time it connects or at once if it's connected.
struct RemotesSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.watchSetup) private var watch
    @State private var confirmBolus = false

    private var settings: AppSettings { model.settings }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                if let watch {
                    LabeledContent("Watch", value: watch.deviceName ?? "Not chosen")
                    LabeledContent("Link", value: linkText)
                    Button("Choose watch in Garmin Connect") { watch.selectDevice() }
                    Button("Get the faBolus watch app") { watch.openStore() }
                    if watch.deviceName != nil { Button("Forget watch", role: .destructive) { watch.forgetDevice() } }
                } else {
                    Label("Garmin not included in this build", systemImage: "exclamationmark.triangle").foregroundStyle(
                        .secondary)
                }
            } header: {
                Text("Garmin watch")
            } footer: {
                if watch == nil {
                    Text(
                        "This build was compiled without Garmin's Connect IQ SDK. Add the SDK and rebuild to use a watch."
                    )
                }
            }
            Section {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                Toggle("Read-only (view only)", isOn: $settings.remotesReadOnly)
                Toggle("Allow bolusing from the watch", isOn: bolusBinding)
                if settings.garminBolusEnabled {
                    Toggle("Limit remote bolus size", isOn: limitOn)
                    if let limit = settings.remoteBolusLimitUnits {
                        Picker("Max per remote bolus", selection: limitValue(limit)) {
                            ForEach(AppSettings.remoteBolusLimitOptions, id: \.self) { Text(unitsText($0)).tag($0) }
                        }
                    }
                }
            } header: {
                Text("Bolusing")
            } footer: {
                Text("Every watch bolus needs the 1 → 2 → 3 confirm on the watch. The pump's own limits always apply.")
            }
            Section {
                Picker("Default mode", selection: $settings.watchDefaultBolusMode) {
                    Text("Carbs").tag(BolusEntryMode.carbs)
                    Text("Units").tag(BolusEntryMode.units)
                }
                LabeledContent(
                    "Increments", value: "\(unitsText(settings.bolusIncrement)), \(settings.carbIncrement) g")
            } header: {
                Text("Watch bolus screen")
            } footer: {
                Text("The increments are the phone's (Bolus & entry).")
            }
            Section {
                NavigationLink {
                    CustomizeListView(
                        title: "Watch screens", allIDs: WatchScreen.allIDs,
                        label: { WatchScreen(rawValue: $0)?.label ?? $0 },
                        order: $settings.watchScreenOrder, footer: "Screens of the watch app, in swipe order.")
                } label: {
                    LabeledContent("Screens", value: "\(settings.watchScreenOrder.count) shown")
                }
                Picker("Opens on", selection: $settings.watchDefaultScreen) {
                    ForEach(settings.watchScreenOrder, id: \.self) {
                        Text(WatchScreen(rawValue: $0)?.label ?? $0).tag($0)
                    }
                }
                NavigationLink {
                    CustomizeListView(
                        title: "Watch details", allIDs: DetailsField.allIDs,
                        label: { DetailsField(rawValue: $0)?.label ?? $0 },
                        order: $settings.watchDetailsOrder, footer: "Rows of the watch's Details screen.")
                } label: {
                    LabeledContent("Details rows", value: "\(settings.watchDetailsOrder.count) shown")
                }
                NavigationLink {
                    WatchChartRangesView(settings: settings)
                } label: {
                    LabeledContent(
                        "Chart ranges", value: settings.watchChartRanges.map { "\($0)h" }.joined(separator: " "))
                }
                Toggle("Own chart bounds", isOn: ownBounds)
                if let floor = settings.watchPlotFloor, let ceiling = settings.watchPlotCeiling {
                    Picker("Plot ceiling", selection: bound(\.watchPlotCeiling, ceiling)) {
                        ForEach(GlucosePlotScale.ceilingOptions, id: \.self) {
                            Text(GlucosePlotScale.boundLabel($0, unit: settings.glucoseUnit)).tag($0)
                        }
                    }
                    Picker("Plot floor", selection: bound(\.watchPlotFloor, floor)) {
                        ForEach(GlucosePlotScale.floorOptions, id: \.self) {
                            Text(GlucosePlotScale.boundLabel($0, unit: settings.glucoseUnit)).tag($0)
                        }
                    }
                }
            } header: {
                Text("Watch layout")
            } footer: {
                Text("Without its own bounds, the watch's chart uses the phone's.")
            }
            Section {
                NavigationLink {
                    CustomizeListView(
                        title: "Complications", allIDs: AppSettings.complicationFields, label: Self.complicationLabel,
                        order: complicationSlots, footer: "Up to three, besides glucose.")
                } label: {
                    LabeledContent(
                        "Complication slots",
                        value: settings.complicationSlots.map(Self.complicationLabel).joined(separator: ", "))
                }
                Toggle("Show names (“IOB 1.25”)", isOn: $settings.complicationNames)
            } header: {
                Text("Complications")
            } footer: {
                Text("Off, a slot shows its value alone. Each watch face decides what it draws.")
            }
        }
        .navigationTitle("Watch")
        .confirmationDialog("Allow bolusing from the watch?", isPresented: $confirmBolus, titleVisibility: .visible) {
            Button("Allow bolusing") { settings.garminBolusEnabled = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This lets you deliver real insulin from your Garmin watch. A Garmin has no wrist detection, so take extra care that a bolus is never started by an accidental button press — it stays off until you allow it here, and every bolus still needs your confirmation on the watch. You can turn this off any time."
            )
        }
    }

    static func complicationLabel(_ id: String) -> String {
        switch id {
        case "iob": return "Active insulin"
        case "reservoir": return "Reservoir"
        case "battery": return "Pump battery"
        case "basal": return "Basal rate"
        default: return id
        }
    }

    private var summary: String {
        if settings.remotesReadOnly { return "The watch can view, not bolus." }
        if !settings.garminBolusEnabled { return "Bolusing from the watch is off." }
        if let limit = settings.remoteBolusLimitUnits {
            return "The watch can bolus, up to \(unitsText(limit)) a dose."
        }
        return "The watch can bolus."
    }

    private var linkText: String {
        guard let w = model.watch else { return "—" }
        switch w.phase {
        case .notPaired: return "No watch chosen"
        case .appNotInstalled: return "faBolus not installed on the watch"
        case .unreachable: return "Not connected"
        case .reachable: return "Connected"
        case .awaitingReply: return "Sending"
        case .backingOff: return "Retrying"
        }
    }

    private var bolusBinding: Binding<Bool> {
        Binding(
            get: { settings.garminBolusEnabled },
            set: { on in if on { confirmBolus = true } else { settings.garminBolusEnabled = false } })
    }

    private var limitOn: Binding<Bool> {
        Binding(get: { settings.remoteBolusLimitUnits != nil }, set: { settings.remoteBolusLimitUnits = $0 ? 5 : nil })
    }

    private func limitValue(_ current: Double) -> Binding<Double> {
        Binding(get: { settings.remoteBolusLimitUnits ?? current }, set: { settings.remoteBolusLimitUnits = $0 })
    }

    private var ownBounds: Binding<Bool> {
        Binding(
            get: { settings.watchPlotFloor != nil },
            set: { on in
                settings.watchPlotFloor = on ? settings.glucosePlotFloor : nil
                settings.watchPlotCeiling = on ? settings.glucosePlotCeiling : nil
            })
    }

    private func bound(_ key: ReferenceWritableKeyPath<AppSettings, Int?>, _ current: Int) -> Binding<Int> {
        Binding(get: { settings[keyPath: key] ?? current }, set: { settings[keyPath: key] = $0 })
    }

    private var complicationSlots: Binding<[String]> {
        Binding(get: { settings.complicationSlots }, set: { settings.complicationSlots = Array($0.prefix(3)) })
    }
}

struct WatchChartRangesView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(AppSettings.watchChartRangeOptions, id: \.self) { hours in
                    Toggle(
                        "\(hours) hours",
                        isOn: Binding(
                            get: { settings.watchChartRanges.contains(hours) },
                            set: { on in
                                var ranges = Set(settings.watchChartRanges)
                                if on { ranges.insert(hours) } else if ranges.count > 1 { ranges.remove(hours) }
                                settings.watchChartRanges = ranges.sorted()
                            }))
                }
            } footer: {
                Text("The ranges a tap on the watch's chart steps through. At least one stays on.")
            }
        }
        .navigationTitle("Chart ranges")
    }
}

extension EnvironmentValues {
    @Entry var watchSetup: WatchSetup?
}
