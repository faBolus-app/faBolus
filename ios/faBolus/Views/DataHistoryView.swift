import SwiftUI
import faBolusCore
import TherapyInsightsKit

/// Data & History settings — time-in-range from the persisted store, storage size, an optional
/// retention (auto-delete) control, and a clear-history action. Storage is ~1 MB/month, so the default
/// is "keep everything"; the retention picker only exists for data-minimization. See MIGRATION.md.
struct DataHistoryView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var confirmClear = false
    @State private var stats: GlucoseStatistics?
    @State private var insights: [PatternInsights.Insight] = []
    @State private var sensitivity: SensitivityMonitor.State?
    @State private var advice: TherapyAdvice?

    private let retentionOptions: [(label: String, days: Int)] = [
        ("Keep everything", 0), ("90 days", 90), ("1 year", 365),
    ]

    var body: some View {
        Form {
            Section("Time in range (last 90 days)") {
                if let s = stats, s.count > 0 {
                    LabeledContent("Time in range", value: "\(Int(s.timeInRangePct))%")
                    LabeledContent("Average", value: "\(Int(s.mean)) mg/dL")
                    LabeledContent("GMI", value: String(format: "%.1f%%", s.gmi))
                    LabeledContent("Readings", value: "\(s.count)")
                } else {
                    Text("No stored history yet — it fills in as glucose comes in.")
                        .foregroundStyle(.secondary)
                }
            }

            if !insights.isEmpty {
                Section("Insights") {
                    ForEach(insights.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insights[i].title).font(.subheadline.weight(.semibold))
                            Text(insights[i].detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if hasSuggestions {
                Section {
                    if let s = sensitivity, s.level != .unknown {
                        LabeledContent("Insulin sensitivity", value: s.level.rawValue.capitalized)
                        if !s.note.isEmpty { Text(s.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let isf = advice?.isf {
                        LabeledContent("Suggested ISF", value: "\(Int(isf)) mg/dL/U")
                    }
                    if let cr = advice?.carbRatio {
                        LabeledContent("Suggested carb ratio", value: "\(Int(cr)) g/U")
                    }
                    if let basal = advice?.basalByHour, basal.contains(where: { $0 != nil }) {
                        let n = basal.filter { $0 != nil }.count
                        LabeledContent("Basal tweaks suggested", value: "\(n) hour\(n == 1 ? "" : "s")")
                        if !model.basalScheduleSource.isEmpty {
                            Text("Basal schedule from \(model.basalScheduleSource).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Settings suggestions (advisory)") } footer: {
                    Text("Derived from your own data — **advisory only, discuss with your clinician** before changing pump settings.\(model.basalByHour() == nil ? " (Basal suggestions need the pump's basal schedule — connect the pump or a Nightscout profile.)" : "")")
                }
            }

            Section {
                LabeledContent("Stored on this device", value: sizeText)
                Picker("Keep history for", selection: $settings.historyRetentionDays) {
                    ForEach(retentionOptions, id: \.days) { Text($0.label).tag($0.days) }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("faBolus keeps your glucose, insulin and carb history on this device to power stats, charts, and smart-assist advice — about **1 MB per month**, so keeping everything is fine. This control is only if you prefer to auto-delete older data.")
            }

            Section {
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear stored history", systemImage: "trash")
                }
            } footer: {
                Text("Permanently deletes all stored glucose/insulin/carb history from this device. Your pump and CGM are not affected.")
            }
        }
        .navigationTitle("Data & History")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all stored history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.clearStoredHistory(); reload() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { model.applyRetention(days: settings.historyRetentionDays); reload() }
        .task {
            // Fallback: grab the pump's basal schedule if no external one is cached (enables basal advice).
            if model.basalByHour() == nil { await model.captureBasalScheduleFromPump(); reload() }
        }
        .onChange(of: settings.historyRetentionDays) { _, days in
            model.applyRetention(days: days); reload()
        }
    }

    private var sizeText: String {
        let mb = Double(model.storedHistoryApproxBytes()) / 1_000_000
        return mb < 1 ? String(format: "~%.0f KB", mb * 1000) : String(format: "~%.1f MB", mb)
    }

    private var hasSuggestions: Bool {
        (sensitivity != nil && sensitivity?.level != .unknown) || advice?.isf != nil || advice?.carbRatio != nil
            || (advice?.basalByHour.contains { $0 != nil } ?? false)
    }

    private func reload() {
        stats = model.storedStatistics(days: 90)
        insights = model.therapyInsights()
        sensitivity = model.sensitivityState()
        advice = model.settingsAdvice()
    }
}
