// Ported from LoopPowerPack/Loop @ ad4c4d4 (MIT)
//
// SiteAtlasRootView — re-skinned root of the SiteAtlas infusion-site / CGM-sensor body-map tracker.
// Advisory / display-only: nothing here originates, pre-fills, or gates a dose (T-09.18a-14).

import SwiftUI
import faBolusDesign
import HistoryStore

/// The SiteAtlas screen: a front/back segmented control over a body map with age-faded site markers,
/// an empty state, and a chronological history list with swipe-to-delete. All logging/reading flows
/// through `SiteAtlasStore` → the `StoredSite` CRUD (09.18a-01).
struct SiteAtlasRootView: View {
    @State private var store: SiteAtlasStore
    @State private var side: SiteAtlas_BodySide = .front
    @State private var sites: [SiteAtlasStore.Site] = []
    @State private var logContext: LogContext?
    @State private var pendingDelete: SiteAtlasStore.Site?

    /// WR-02: inject the app's SHARED `GlucoseHistoryStore` so the body map reads/writes the SAME store
    /// backup + export use — not a private second `ModelContainer` over the same file. A `nil` store
    /// (failed to open at app init) degrades to a visible "unavailable" banner with logging disabled,
    /// never a silent no-op that drops the placement.
    init(historyStore: GlucoseHistoryStore?) {
        _store = State(initialValue: SiteAtlasStore(history: historyStore))
    }

    /// Identifies a pending log-entry sheet + the body coordinate the user tapped.
    private struct LogContext: Identifiable {
        let id = UUID()
        let normalizedX: Double
        let normalizedY: Double
    }

    var body: some View {
        Form {
            if !store.isAvailable {
                Section {
                    Label("Site history is unavailable — the on-device store didn't open. Reopen faBolus; if this persists, your data store may need attention.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.stale)
                }
            }
            Section {
                Picker("Body side", selection: $side) {
                    ForEach(SiteAtlas_BodySide.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .tint(AppTheme.insulin)

                SiteAtlasBodyMapView(side: side, sites: sitesOnSide) { x, y in
                    guard store.isAvailable else { return }   // WR-02: never no-op a tap silently
                    logContext = LogContext(normalizedX: x, normalizedY: y)
                }
                .frame(maxWidth: AppTheme.iPadReadableContentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)   // 2xl breathing room
            }

            if sites.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("No sites logged yet")
                            .font(.headline)
                        Text("Tap a spot on the body map to log where your infusion set or sensor is. faBolus tracks age and reminds you about reused spots.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section("History") {
                    ForEach(sites) { site in
                        SiteHistoryRow(site: site)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = site
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Site Atlas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    logContext = LogContext(normalizedX: 0.5, normalizedY: 0.5)
                } label: {
                    Label("Log site", systemImage: "plus")
                }
                .disabled(!store.isAvailable)   // WR-02: no logging when the store is unavailable
            }
        }
        .sheet(item: $logContext) { ctx in
            SiteAtlasLogEntrySheet(store: store, bodySide: side,
                                   normalizedX: ctx.normalizedX, normalizedY: ctx.normalizedY) {
                reload()
            }
        }
        .confirmationDialog("Delete this site entry? This removes it from your history and backup.",
                            isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = pendingDelete {
                    store.delete(id: target.id)
                    reload()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .onAppear(perform: reload)
    }

    private var sitesOnSide: [SiteAtlasStore.Site] {
        sites.filter { $0.bodySide == side }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    private func reload() {
        sites = store.allSites()
    }
}

/// One row in the chronological site history: kind icon, anatomical location, age, optional note.
private struct SiteHistoryRow: View {
    let site: SiteAtlasStore.Site

    private var symbol: String {
        site.type == .pump ? "bandage.fill" : "sensor.tag.radiowaves.forward.fill"
    }

    private var ageText: String {
        let days = site.daysSincePlaced
        if days == 0 { return "Today" }
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(site.isPastReuseWindow ? AppTheme.stale : AppTheme.insulin)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.locationDescription)
                    .font(.headline)
                if let note = site.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(ageText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
