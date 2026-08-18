// Adapted from LoopPowerPack/Loop @ ad4c4d4 (MIT)
//
//  LoopInsights_CaffeineLogView.swift — 09.18d-02 (D-14/D-15/D-17).
//
//  The benign caffeine tracker log surface: a chronological log list + a "Log caffeine" entry sheet
//  (amount + time), with a compact glucose-context readout from the 09.18d-01 aggregator so entries are
//  seen alongside glucose. Re-skinned in faBolusDesign from the LoopPowerPack CaffeineLogView LAYOUT —
//  no LoopKit, no risk/warning/directive copy. Informational only: faBolus never changes a dose (§13).

import SwiftUI
import faBolusCore
import faBolusDesign
import HistoryStore

/// Sane ceiling for a single caffeine entry (mg). A finite value above this — or any non-finite paste
/// (e.g. `1e400` → `+inf`) — is rejected at the entry sheet (H-01/M-01) and clamped on display via the
/// shared `clampedInt` funnel, so even a legacy persisted bad value renders without tripping `Int(_:)`.
private let maxCaffeineMilligrams = 100_000

struct LoopInsights_CaffeineLogView: View {
    /// Optional to mirror the endo report view — a nil shared store degrades to the empty state
    /// rather than crashing.
    let historyStore: GlucoseHistoryStore?
    /// The app's glucose display unit, for the glucose-context readout.
    var glucoseUnit: GlucoseUnit

    @State private var entries: [CaffeineEntry] = []
    @State private var showingLogSheet = false
    @State private var entryToDelete: CaffeineEntry?

    private var tracker: LoopInsights_CaffeineTracker { LoopInsights_CaffeineTracker(store: historyStore) }
    private var unitContext: InsightsGlucoseUnitContext { InsightsGlucoseUnitContext(unit: glucoseUnit) }
    private var glucoseReport: FaBolusInsightsReport? {
        guard let historyStore else { return nil }
        return FaBolusInsightsAggregator(store: historyStore).report(period: .days(14))
    }

    var body: some View {
        Form {
            TrackerGlucoseContextSection(report: glucoseReport, unitContext: unitContext)

            Section {
                if entries.isEmpty {
                    Text("Nothing logged yet. Log entries here to see them alongside your glucose. Informational only — faBolus won't change any dose.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.source)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(clampedInt(entry.milligrams, max: maxCaffeineMilligrams)) mg")
                                .monospacedDigit()
                                .foregroundStyle(AppTheme.carbs)
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { entryToDelete = entry } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Caffeine log")
            } footer: {
                Text("A record of what you logged, shown alongside your glucose. **Informational only — faBolus won't change any dose.**")
            }

            Section {
                Button {
                    showingLogSheet = true
                } label: {
                    Label("Log caffeine", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("Caffeine")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .sheet(isPresented: $showingLogSheet, onDismiss: reload) {
            CaffeineEntrySheet(tracker: tracker)
        }
        .alert("Delete this entry?", isPresented: Binding(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let e = entryToDelete { tracker.remove(id: e.id) }
                entryToDelete = nil
                reload()
            }
            Button("Cancel", role: .cancel) { entryToDelete = nil }
        }
    }

    private func reload() { entries = tracker.entries() }
}

/// A compact, informational glucose-context readout shared by both tracker log views (09.18d-02). Shows
/// Time-in-Range + average over the last 14 days from the 09.18d-01 aggregator so logged entries are
/// seen "alongside your glucose". Display-only — never advice or a dose (§13). Renders nothing when
/// there isn't enough history yet.
struct TrackerGlucoseContextSection: View {
    let report: FaBolusInsightsReport?
    let unitContext: InsightsGlucoseUnitContext

    var body: some View {
        if let r = report, r.hasSufficientHistory {
            Section {
                HStack {
                    Text(unitContext.tirRangeLabel).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", r.glucose.timeInRangePct)).monospacedDigit()
                }
                HStack {
                    Text("Average glucose").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(unitContext.formatMgdl(r.glucose.average)) \(unitContext.unitString)").monospacedDigit()
                }
            } header: {
                Text("Your glucose · last 14 days")
            } footer: {
                Text("Shown for context alongside what you log. Informational only.")
            }
        }
    }
}

/// The "Log caffeine" entry sheet — amount (mg) + source + time. Writes through the benign tracker.
private struct CaffeineEntrySheet: View {
    let tracker: LoopInsights_CaffeineTracker
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var source = "Coffee"
    @State private var date = Date()

    private var amount: Double? {
        // H-01/M-01: reject non-finite (`.infinity` from a pasted `1e400`) and implausibly-large finite
        // values (a value above `Int.max` would trap the log row's `Int(_:)`) AT THE SEAM, so garbage is
        // never persisted, round-tripped into backup/export, or fed to any tracker math.
        guard let v = Double(amountText.trimmingCharacters(in: .whitespaces)),
              v.isFinite, v > 0, v <= Double(maxCaffeineMilligrams) else { return nil }
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    HStack {
                        TextField("Milligrams", text: $amountText)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                        Text("mg").foregroundStyle(.secondary)
                    }
                }
                Section("Source") {
                    TextField("e.g. Coffee, Tea, Cola", text: $source)
                }
                Section("Time") {
                    DatePicker("When", selection: $date, in: ...Date())
                }
            }
            .navigationTitle("Log caffeine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let mg = amount {
                            let src = source.trimmingCharacters(in: .whitespaces)
                            tracker.log(milligrams: mg, source: src.isEmpty ? "Caffeine" : src, at: date)
                        }
                        dismiss()
                    }
                    .disabled(amount == nil)
                }
            }
        }
    }
}
