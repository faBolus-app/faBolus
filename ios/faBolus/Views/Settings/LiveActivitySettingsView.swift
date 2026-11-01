import PhoneApp
import SwiftUI
import WidgetContent
import faBolusCore

/// The glucose Live Activity on the Lock Screen and in the Dynamic Island.
struct LiveActivitySettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show Live Activity", isOn: $settings.liveActivityEnabled)
            } footer: {
                Text(
                    "Glucose on the Lock Screen and in the Dynamic Island while faBolus runs. It starts the next time you open the app, and shows stale if updates stop."
                )
            }
            if settings.liveActivityEnabled {
                Section("Style") {
                    Picker("Style", selection: layout(\.style)) {
                        Text("Curve").tag(LiveActivityLayout.Style.fullBleed)
                        Text("Number and chips").tag(LiveActivityLayout.Style.classic)
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
                    Toggle("Bolus button", isOn: layout(\.showBolusShortcut))
                } footer: {
                    Text("Opens the bolus screen in the app. Nothing is sent from the Live Activity.")
                }
            }
        }
        .navigationTitle("Live Activity")
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
