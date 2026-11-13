import PhoneApp
import SwiftUI
import WidgetContent
import faBolusCore

/// The glucose Live Activity on the Lock Screen and in the Dynamic Island.
struct LiveActivitySettingsView: View {
    @Bindable var settings: AppSettings
    @State private var confirmBolus = false

    var body: some View {
        Form {
            Section {
                Toggle("Show Live Activity", isOn: $settings.liveActivityEnabled)
            } footer: {
                Text(
                    "Glucose on the Lock Screen, in the Dynamic Island, and on a Mac, in CarPlay or on an Apple Watch that shows your iPhone's Live Activities, while faBolus runs. It starts the next time you open the app, and shows stale if updates stop."
                )
            }
            if settings.liveActivityEnabled {
                Section("Style") {
                    Picker("Style", selection: layout(\.style)) {
                        Text("Curve").tag(LiveActivityLayout.Style.fullBleed)
                        Text("Chips").tag(LiveActivityLayout.Style.classic)
                        Text("Slim").tag(LiveActivityLayout.Style.slim)
                    }
                    .pickerStyle(.segmented)
                    if settings.liveActivityLayout.style == .fullBleed {
                        Picker("Top right", selection: layout(\.topRight)) {
                            ForEach(LiveActivityTopRight.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Picker("Chart span", selection: layout(\.plotRangeHours)) {
                        ForEach(LiveActivityLayout.plotRangeOptions, id: \.self) { Text("\($0) h").tag($0) }
                    }
                }
                Section {
                    Picker("Beside the glucose", selection: compact) {
                        ForEach(LiveActivityCompact.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Dynamic Island and Mac menu bar")
                } footer: {
                    Text(
                        "The small view shows the glucose, a ⚠ while a pump alert is open, and this beside it. While a bolus from the Live Activity is going, it shows that instead."
                    )
                }
                Section {
                    NavigationLink {
                        CustomizeListView(
                            title: "Fields", allIDs: LiveActivityField.allCases.map(\.rawValue),
                            label: { LiveActivityField(rawValue: $0)?.label ?? $0 }, order: fields,
                            footer:
                                "What the Live Activity shows, in order. The Dynamic Island shows the first ones that fit."
                        )
                    } label: {
                        LabeledContent("Fields", value: "\(settings.liveActivityLayout.fields.count) shown")
                    }
                }
                Section("Chart") {
                    Toggle("Time axis line", isOn: layout(\.showXAxisLine))
                    Toggle("Glucose axis line", isOn: layout(\.showYAxisLine))
                    Toggle("Time ticks", isOn: layout(\.showXAxisTicks))
                    Toggle("Glucose ticks", isOn: layout(\.showYAxisTicks))
                    Toggle("Range lines (70 and 180)", isOn: layout(\.showRangeLines))
                }
                Section {
                    Toggle("Allow bolusing from the Live Activity", isOn: bolusBinding)
                } header: {
                    Text("Bolusing")
                } footer: {
                    Text(bolusFooter)
                }
            }
        }
        .navigationTitle("Live Activity")
        .confirmationDialog(
            "Allow bolusing from the Live Activity?", isPresented: $confirmBolus, titleVisibility: .visible
        ) {
            Button("Allow bolusing") { settings.liveActivityBolusEnabled = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This lets you deliver real insulin from the Live Activity on the Lock Screen, in the Dynamic Island and on a Mac that shows your iPhone's Live Activities. iOS asks you to unlock first, and every bolus still needs 1 → 2 → 3 on the Live Activity. You can turn this off any time."
            )
        }
    }

    /// The compact view's choice, the trend arrow when none was made.
    private var compact: Binding<LiveActivityCompact> {
        Binding(
            get: { settings.liveActivityLayout.compact ?? .arrow }, set: { settings.liveActivityLayout.compact = $0 })
    }

    private var bolusBinding: Binding<Bool> {
        Binding(
            get: { settings.liveActivityBolusEnabled },
            set: { on in if on { confirmBolus = true } else { settings.liveActivityBolusEnabled = false } })
    }

    private var bolusFooter: String {
        if settings.remotesReadOnly || settings.phoneReadOnly {
            return "Read-only is on, so the Live Activity can't bolus. Cancel and clearing alerts still work."
        }
        let limit =
            settings.remoteBolusLimitUnits.map { " The remote limit of \(formatUnits($0)) a dose applies." } ?? ""
        return
            "Every bolus needs 1 → 2 → 3 on the Live Activity, as on the watch. Cancel and pump alerts are always there. CarPlay and the Apple Watch show the Live Activity without buttons.\(limit)"
    }

    private func layout<V>(_ key: WritableKeyPath<LiveActivityLayout, V>) -> Binding<V> {
        Binding(
            get: { settings.liveActivityLayout[keyPath: key] }, set: { settings.liveActivityLayout[keyPath: key] = $0 })
    }

    private var fields: Binding<[String]> {
        Binding(
            get: { settings.liveActivityLayout.fields.map(\.rawValue) },
            set: { settings.liveActivityLayout.fields = $0.compactMap(LiveActivityField.init(rawValue:)) })
    }
}
