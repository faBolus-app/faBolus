// Adapted from LoopPowerPack/Loop @ ad4c4d4 (MIT)
//
//  LoopInsights_AlcoholLogView.swift — 09.18d-02 (D-14/D-15/D-17).
//
//  The benign alcohol tracker log surface: a chronological log list + a "Log a drink" entry sheet
//  (amount + time), with a compact glucose-context readout from the 09.18d-01 aggregator so entries are
//  seen alongside glucose. Re-skinned in faBolusDesign from the LoopPowerPack AlcoholLogView LAYOUT —
//  no LoopKit, and the mirror's delayed-hypo RISK copy is NOT reproduced (D-14). Informational only:
//  faBolus never changes a dose (§13).

import SwiftUI
import faBolusCore
import faBolusDesign
import HistoryStore

/// Sane ceiling for a single alcohol entry (standard drinks). A finite value above this — or any
/// non-finite paste — is rejected at the entry sheet (M-01), mirroring the caffeine mg cap.
private let maxStandardDrinks = 100.0

struct LoopInsights_AlcoholLogView: View {
    /// Optional to mirror the endo report view — a nil shared store degrades to the empty state.
    let historyStore: GlucoseHistoryStore?
    /// The app's glucose display unit, for the glucose-context readout.
    var glucoseUnit: GlucoseUnit

    @State private var entries: [AlcoholEntry] = []
    @State private var showingLogSheet = false
    @State private var entryToDelete: AlcoholEntry?

    private var tracker: LoopInsights_AlcoholTracker { LoopInsights_AlcoholTracker(store: historyStore) }
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
                            Text(drinksLabel(entry.standardDrinks))
                                .monospacedDigit()
                                .foregroundStyle(AppTheme.insulin)
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
                Text("Drink log")
            } footer: {
                Text("A record of what you logged, shown alongside your glucose. **Informational only — faBolus won't change any dose.**")
            }

            Section {
                Button {
                    showingLogSheet = true
                } label: {
                    Label("Log a drink", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("Alcohol")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .sheet(isPresented: $showingLogSheet, onDismiss: reload) {
            AlcoholEntrySheet(tracker: tracker)
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

    /// "1 drink" / "1.5 drinks" — trimmed, no trailing zeros. Non-finite (a legacy persisted `inf`/`nan`)
    /// renders as "0 drinks" rather than "inf drinks" (M-01 defense-in-depth on read).
    private func drinksLabel(_ n: Double) -> String {
        let safe = n.isFinite ? n : 0
        let s = String(format: "%g", safe)
        return "\(s) \(safe == 1 ? "drink" : "drinks")"
    }
}

/// The "Log a drink" entry sheet — standard drinks + source + time. Writes through the benign tracker.
private struct AlcoholEntrySheet: View {
    let tracker: LoopInsights_AlcoholTracker
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = "1"
    @State private var source = "Drink"
    @State private var date = Date()

    private var amount: Double? {
        // M-01: reject non-finite and implausibly-large finite values AT THE SEAM (shared root cause with
        // H-01) so garbage never persists, round-trips into backup/export, or feeds any tracker math.
        guard let v = Double(amountText.trimmingCharacters(in: .whitespaces)),
              v.isFinite, v > 0, v <= maxStandardDrinks else { return nil }
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Standard drinks", text: $amountText)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                        Text("drinks").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    Text("One standard drink ≈ 12 oz beer, 5 oz wine, or 1.5 oz spirits.")
                }
                Section("Source") {
                    TextField("e.g. Beer, Wine, Cocktail", text: $source)
                }
                Section("Time") {
                    DatePicker("When", selection: $date, in: ...Date())
                }
            }
            .navigationTitle("Log a drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let n = amount {
                            let src = source.trimmingCharacters(in: .whitespaces)
                            tracker.log(standardDrinks: n, source: src.isEmpty ? "Drink" : src, at: date)
                        }
                        dismiss()
                    }
                    .disabled(amount == nil)
                }
            }
        }
    }
}
