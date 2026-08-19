import SwiftUI
import faBolusCore

/// D-12: a real, non-debug CGM-status surface listing every CONFIGURED failover source's live
/// status/age/provenance — reusing the SAME already-arbitrated `GlucoseProvenance` the live "via
/// <source>" badge and `CgmArbiterDiagnostics` read (never re-running `GlucoseArbiter.merge`). It
/// distinguishes the ACTIVE failover from a source that is merely configured-but-not-selected, and —
/// per F-18 — surfaces a source that is SELECTED but not yet ARMED (the selection takes effect on the
/// next launch), so a passing Test on an unarmed source is never mistaken for the live feed. Replaces
/// the 7-tap hidden debug menu as the place this information exists (F-08/F-09); reachable from
/// Settings › CGM & failover.
///
/// The classification/row/label/detail logic is PURE and `static` (mirroring
/// `CgmCredentialsView.testOutcome`/`sourcesToTest`), so it is unit-tested by `CgmStatusSurfaceTests`
/// without a live view. The `body` only wires already-tracked model state into those pure helpers —
/// no new persisted state, no dose logic, no re-arbitration.
struct CgmStatusView: View {
    let model: AppModel

    // MARK: - Pure, unit-testable status model

    /// How one CONFIGURED failover source relates to the live glucose picture (D-12).
    enum Classification: Equatable {
        case activeFailover        // arbitrated as the live source right now (provenance == .failover(this))
        case armedPumpLive         // the running source, but the pump feed is live (no failover active)
        case selectedNotArmed      // selected in Settings but not yet the running instance — reopen to arm (F-18)
        case configuredNotSelected // has saved config but isn't the selected source
    }

    /// One row of the surface. Live `statusCaseName`/`ageSeconds` are populated ONLY for the armed
    /// source (the sole source with a running instance / live probe); nil for every other row.
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        let classification: Classification
        let statusCaseName: String?
        let ageSeconds: Int?
    }

    /// Pure classification of one source id against the live selection / arming / provenance state.
    /// No UserDefaults, no view — the active-failover decision is read from the already-arbitrated
    /// `provenance` (never recomputed here). `nonisolated` (like `CgmCredentialsView`'s pure helpers)
    /// so `CgmStatusSurfaceTests` can exercise it off the main actor without instantiating the view.
    nonisolated static func classify(sourceId: String, selectedId: String?, armedId: String?,
                                     provenance: GlucoseProvenance) -> Classification {
        if case let .failover(activeId, _) = provenance, activeId == sourceId {
            return .activeFailover
        }
        if armedId == sourceId { return .armedPumpLive }
        if selectedId == sourceId { return .selectedNotArmed }
        return .configuredNotSelected
    }

    /// Pure row builder: one `Row` per configured source, live status/age attached only to the armed
    /// one. Order is the caller's (registry order in the view).
    nonisolated static func rows(configured: [(id: String, name: String)],
                                 selectedId: String?, armedId: String?,
                                 provenance: GlucoseProvenance,
                                 armedStatusCaseName: String?, armedAgeSeconds: Int?) -> [Row] {
        configured.map { c in
            let cls = classify(sourceId: c.id, selectedId: selectedId, armedId: armedId, provenance: provenance)
            let isArmed = (armedId == c.id)
            return Row(id: c.id, name: c.name, classification: cls,
                       statusCaseName: isArmed ? armedStatusCaseName : nil,
                       ageSeconds: isArmed ? armedAgeSeconds : nil)
        }
    }

    /// Case-name-only projection of a `GlucoseSourceStatus`, discarding `.error`'s associated string —
    /// the SAME redaction `CgmArbiterDiagnostics.caseName` applies (an upstream error message never
    /// reaches this surface).
    nonisolated static func statusCaseName(_ status: GlucoseSourceStatus) -> String {
        switch status {
        case .idle:       return "idle"
        case .needsSetup: return "needsSetup"
        case .searching:  return "searching"
        case .connected:  return "connected"
        case .stale:      return "stale"
        case .error:      return "error"
        }
    }

    /// Short human label for a row's classification.
    nonisolated static func classificationLabel(_ c: Classification) -> String {
        switch c {
        case .activeFailover:        return "Active failover — live now"
        case .armedPumpLive:         return "Armed — pump feed is live"
        case .selectedNotArmed:      return "Selected — reopen the app to arm"
        case .configuredNotSelected: return "Configured — not selected"
        }
    }

    /// Live status + age line for the armed source.
    nonisolated static func rowDetail(statusCaseName: String, ageSeconds: Int?) -> String {
        guard let a = ageSeconds else { return "\(statusCaseName) · no reading yet" }
        let ageStr = a < 60 ? "\(a)s ago" : "\(a / 60) min ago"
        return "\(statusCaseName) · last reading \(ageStr)"
    }

    // MARK: - View wiring (reads already-tracked model state only)

    /// Sources considered "configured": the selected source, the armed source, and any source with
    /// saved cloud credentials — presented in registry order. Credential-less sources (G7/G6/HealthKit/
    /// xDrip) only appear once selected/armed, since they have nothing to configure until chosen.
    private func configuredSources() -> [(id: String, name: String)] {
        var ids = Set<String>()
        if let s = GlucoseSourceRegistry.selectedId(), !s.isEmpty { ids.insert(s) }
        if let armed = model.glucoseSourceProbe?.id { ids.insert(armed) }
        if GlucoseSourceConfig.string("nightscout.url") != nil { ids.insert("nightscout") }
        if GlucoseSourceConfig.string("dexcomshare.username") != nil { ids.insert("dexcom-share") }
        if GlucoseSourceConfig.string("librelinkup.username") != nil { ids.insert("librelinkup") }
        return GlucoseSourceRegistry.enabled
            .filter { ids.contains($0.id) }
            .map { (id: $0.id, name: $0.name) }
    }

    private var statusRows: [Row] {
        let probe = model.glucoseSourceProbe
        let age = probe?.latest.map { Int(max(0, Date().timeIntervalSince($0.date))) }
        return Self.rows(configured: configuredSources(),
                         selectedId: GlucoseSourceRegistry.selectedId(),
                         armedId: probe?.id,
                         provenance: model.glucoseProvenance,
                         armedStatusCaseName: probe.map { Self.statusCaseName($0.status) },
                         armedAgeSeconds: age)
    }

    /// True when the persisted selection differs from the running instance — the F-18 case that a Test
    /// runs against a source that isn't armed yet.
    private var needsRelaunchToArm: Bool {
        guard let sel = GlucoseSourceRegistry.selectedId(), !sel.isEmpty else { return false }
        return model.glucoseSourceProbe?.id != sel
    }

    var body: some View {
        Form {
            Section {
                if statusRows.isEmpty {
                    Text("No failover source is configured yet. Pick one under **Settings › CGM & failover**.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(statusRows) { row in statusRowView(row) }
                }
            } header: {
                Text("Configured sources")
            } footer: {
                Text("Live status for each source you've configured. Only ONE source is armed at a time — the one you selected — so status and age are live only for that source; the rest are shown for reference. This reads the same arbitration the live glucose badge uses; it never changes how the app doses.")
            }

            if needsRelaunchToArm {
                Section {
                    Label {
                        Text("You changed your failover source — **reopen the app to arm it**. Until then, a **Test** runs against the newly-selected source, but the previously-armed source is still what would actually drive failover.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("CGM source status")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func statusRowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.name).font(.subheadline)
                Spacer()
                Text(Self.classificationLabel(row.classification))
                    .font(.caption)
                    .foregroundStyle(row.classification == .activeFailover ? Color.green : Color.secondary)
            }
            if let s = row.statusCaseName {
                Text(Self.rowDetail(statusCaseName: s, ageSeconds: row.ageSeconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
