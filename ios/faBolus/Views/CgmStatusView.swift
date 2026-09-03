import SwiftUI
import faBolusCore
import faBolusDesign

/// Lists every configured failover source's live status, age, and provenance. Reads the SAME
/// already-arbitrated `GlucoseProvenance` the live "via <source>" badge uses — never re-runs
/// `GlucoseArbiter.merge`. Distinguishes the active failover from configured-but-not-selected, and
/// surfaces selected-but-not-yet-armed (selection takes effect on the next launch) so a passing Test
/// on an unarmed source is never mistaken for the live feed. Reachable from Settings › CGM & failover.
///
/// Classification/row/label/detail logic is pure and `static` so it can be unit-tested without a live
/// view. The `body` only wires already-tracked model state into those helpers — no new persisted
/// state, no dose logic, no re-arbitration.
struct CgmStatusView: View {
    let model: AppModel

    // MARK: - Pure, unit-testable status model

    /// How one configured failover source relates to the live glucose picture.
    enum Classification: Equatable {
        case activeFailover  // arbitrated as the live source right now (provenance == .failover(this))
        case armedPumpLive  // the running source, but the pump feed is live (no failover active)
        case selectedNotArmed  // selected in Settings but not yet the running instance — reopen to arm
        case configuredNotSelected  // has saved config but isn't the selected source
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
    nonisolated static func classify(
        sourceId: String, selectedId: String?, armedId: String?,
        provenance: GlucoseProvenance
    ) -> Classification {
        if case let .failover(activeId, _) = provenance, activeId == sourceId {
            return .activeFailover
        }
        if armedId == sourceId { return .armedPumpLive }
        if selectedId == sourceId { return .selectedNotArmed }
        return .configuredNotSelected
    }

    /// Pure row builder: one `Row` per configured source, live status/age attached only to the armed
    /// one. Order is the caller's (registry order in the view).
    nonisolated static func rows(
        configured: [(id: String, name: String)],
        selectedId: String?, armedId: String?,
        provenance: GlucoseProvenance,
        armedStatusCaseName: String?, armedAgeSeconds: Int?
    ) -> [Row] {
        configured.map { c in
            let cls = classify(sourceId: c.id, selectedId: selectedId, armedId: armedId, provenance: provenance)
            let isArmed = (armedId == c.id)
            return Row(
                id: c.id, name: c.name, classification: cls,
                statusCaseName: isArmed ? armedStatusCaseName : nil,
                ageSeconds: isArmed ? armedAgeSeconds : nil)
        }
    }

    /// Case-name-only projection of a `GlucoseSourceStatus`, discarding `.error`'s associated string —
    /// the SAME redaction `CgmArbiterDiagnostics.caseName` applies (an upstream error message never
    /// reaches this surface).
    nonisolated static func statusCaseName(_ status: GlucoseSourceStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .needsSetup: return "needsSetup"
        case .searching: return "searching"
        case .connected: return "connected"
        case .stale: return "stale"
        case .error: return "error"
        }
    }

    /// Short human label for a row's classification.
    nonisolated static func classificationLabel(_ c: Classification) -> String {
        switch c {
        case .activeFailover: return "Active failover — live now"
        case .armedPumpLive: return "Armed — pump feed is live"
        case .selectedNotArmed: return "Selected — reopen the app to arm"
        case .configuredNotSelected: return "Configured — not selected"
        }
    }

    /// Shared subtitle for Settings' "Configure & test" and "Status" sections. Both MUST agree on
    /// whether a source is selected for the same state — the raw `selectedId()` can be a stale
    /// persisted id that no longer resolves, while `selected()` validates against `enabled`. Callers
    /// must pass the already-validated selection (`GlucoseSourceRegistry.selected()`, not the raw id)
    /// so `nil` always means "not selected" at both call sites. Pure so it is unit-testable without a
    /// live view.
    nonisolated static func selectionStatusSubtitle(
        selected: (id: String, name: String)?, armedId: String?,
        provenance: GlucoseProvenance
    ) -> (text: String, isActive: Bool) {
        guard let selected else {
            return ("Pump only — no failover source selected", false)
        }
        let cls = classify(sourceId: selected.id, selectedId: selected.id, armedId: armedId, provenance: provenance)
        return (classificationLabel(cls), cls == .activeFailover)
    }

    /// Live status + age line for the armed source.
    nonisolated static func rowDetail(statusCaseName: String, ageSeconds: Int?) -> String {
        guard let a = ageSeconds else { return "\(statusCaseName) · no reading yet" }
        let ageStr = a < 60 ? "\(a)s ago" : "\(a / 60) min ago"
        return "\(statusCaseName) · last reading \(ageStr)"
    }

    // MARK: - View wiring (reads already-tracked model state only)

    /// Sources considered "configured": the selected source, the armed source, and any source with
    /// saved cloud credentials — presented in registry order. Credential-less sources (G7/HealthKit)
    /// only appear once selected/armed, since they have nothing to configure until chosen.
    private func configuredSources() -> [(id: String, name: String)] {
        var ids = Set<String>()
        if let s = GlucoseSourceRegistry.selectedId(), !s.isEmpty { ids.insert(s) }
        if let armed = model.glucoseSourceProbe?.id { ids.insert(armed) }
        if GlucoseSourceConfig.string("dexcomshare.username") != nil { ids.insert("dexcom-share") }
        return GlucoseSourceRegistry.enabled
            .filter { ids.contains($0.id) }
            .map { (id: $0.id, name: $0.name) }
    }

    private var statusRows: [Row] {
        let probe = model.glucoseSourceProbe
        let age = probe?.latest.map { Int(max(0, Date().timeIntervalSince($0.date))) }
        return Self.rows(
            configured: configuredSources(),
            selectedId: GlucoseSourceRegistry.selectedId(),
            armedId: probe?.id,
            provenance: model.glucoseProvenance,
            armedStatusCaseName: probe.map { Self.statusCaseName($0.status) },
            armedAgeSeconds: age)
    }

    /// True when the persisted selection differs from the running instance — a Test then runs against
    /// a source that isn't armed yet.
    private var needsRelaunchToArm: Bool {
        guard let sel = GlucoseSourceRegistry.selected() else { return false }
        return model.glucoseSourceProbe?.id != sel.id
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
                Text(
                    "Live status for each source you've configured. Only ONE source is armed at a time — the one you selected — so status and age are live only for that source; the rest are shown for reference. This reads the same arbitration the live glucose badge uses; it never changes how the app doses."
                )
            }

            // Read-only echo of the most recent Test outcome. This page never hosts a Test button
            // or re-triggers the Test flow — that stays on the Configure & test page.
            Section {
                switch model.cgmTestOutcome {
                case nil:
                    Text("No test has been run yet — run **Test** on the CGM credentials & testing page.")
                        .font(.caption).foregroundStyle(.secondary)
                case .waiting:
                    HStack(spacing: 10) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text("Test in progress — waiting for a reading from \(lastTestSourceName)…")
                            .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                case .success(let sample):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.inRange)
                        Text("\(lastTestSourceName): last test succeeded — \(lastTestSuccessDetail(sample))")
                            .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                case .timeout:
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text("\(lastTestSourceName): last test found no reading")
                            .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Last test result")
            } footer: {
                Text(
                    "A read-only echo of the most recent Test you ran on the CGM credentials & testing page. This page never re-runs the test itself."
                )
            }

            if needsRelaunchToArm {
                Section {
                    Label {
                        Text(
                            "You changed your failover source — **reopen the app to arm it**. Until then, a **Test** runs against the newly-selected source, but the previously-armed source is still what would actually drive failover."
                        )
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

    /// Currently-selected source's display name, read from the registry (same convention as
    /// `CgmCredentialsView.selectedSourceName`).
    private var lastTestSourceName: String {
        guard let id = GlucoseSourceRegistry.selectedId() else { return "the selected source" }
        return GlucoseSourceRegistry.descriptor(id: id)?.name ?? id
    }

    /// Compact "{bg} · {age}" success line, matching `CgmCredentialsView.successDetail`'s
    /// display-unit + age-string conventions. No ProgressView, elapsed counter, or error dump —
    /// the full diagnostic stays on the Configure & test page.
    private func lastTestSuccessDetail(_ sample: GlucoseSample) -> String {
        let age = Int(max(0, Date().timeIntervalSince(sample.date)))
        let ageStr = age < 60 ? "\(age)s ago" : "\(age / 60) min ago"
        let bgUnit = AppSettings.shared.glucoseDisplayUnit
        let bgStr = "\(bgUnit.format(mgdl: sample.mgdl)) \(bgUnit == .mmol ? "mmol/L" : "mg/dL")"
        return "\(bgStr) · \(ageStr)"
    }

    @ViewBuilder private func statusRowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.name).font(.subheadline)
                Spacer()
                Text(Self.classificationLabel(row.classification))
                    .font(.caption)
                    // AppTheme.inRange, not system Color.green — one "active/live" green across this
                    // screen family (Last-test success icon, Settings status subtitle).
                    .foregroundStyle(row.classification == .activeFailover ? AppTheme.inRange : Color.secondary)
            }
            if let s = row.statusCaseName {
                Text(Self.rowDetail(statusCaseName: s, ageSeconds: row.ageSeconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
