// Ported from LoopPowerPack/Loop @ ad4c4d4 (MIT)
//
// SiteAtlasLogEntrySheet — re-skinned log-entry sheet for a new SiteAtlas placement.

import SwiftUI
import faBolusDesign

/// A `.sheet` to log a new infusion-set / CGM-sensor placement at a chosen body coordinate. Writes
/// through `SiteAtlasStore` (→ `StoredSite` CRUD). The reuse-window note is ADVISORY and never blocks
/// logging.
struct SiteAtlasLogEntrySheet: View {
    let store: SiteAtlasStore
    let bodySide: SiteAtlas_BodySide
    let normalizedX: Double
    let normalizedY: Double
    /// Called after a successful write so the caller can reload the map/list.
    var onLogged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type: SiteAtlas_SiteType = .pump
    @State private var date = Date()
    @State private var note = ""

    /// Recomputed as the type changes — a same-kind recent site near this spot triggers the advisory.
    private var nearbyRecent: SiteAtlasStore.Site? {
        store.recentNearbySite(type: type, bodySide: bodySide,
                               normalizedX: normalizedX, normalizedY: normalizedY)
    }

    /// IN-01: reuse-advisory timing phrase — "today" / singular "day" / plural "days" (never "0 days
    /// ago" or "1 days ago"), matching `SiteHistoryRow.ageText`'s formatting.
    private func reuseTimingPhrase(_ days: Int) -> String {
        if days == 0 { return "You logged this area earlier today." }
        return "You logged this area \(days) day\(days == 1 ? "" : "s") ago."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        Text("Infusion set").tag(SiteAtlas_SiteType.pump)
                        Text("CGM sensor").tag(SiteAtlas_SiteType.sensor)
                    }
                    .pickerStyle(.segmented)

                    DatePicker("Date & time", selection: $date)

                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let nearby = nearbyRecent {
                    Section {
                        Label {
                            Text("\(reuseTimingPhrase(nearby.daysSincePlaced)) Rotating sites helps absorption.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppTheme.high)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: AppTheme.iPadReadableContentMaxWidth)
            .navigationTitle(type == .pump ? "Log site" : "Log sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(type == .pump ? "Log site" : "Log sensor") {
                        store.add(type: type, bodySide: bodySide,
                                  normalizedX: normalizedX, normalizedY: normalizedY,
                                  note: note, date: date)
                        onLogged()
                        dismiss()
                    }
                    .tint(AppTheme.insulin)
                }
            }
        }
    }
}
