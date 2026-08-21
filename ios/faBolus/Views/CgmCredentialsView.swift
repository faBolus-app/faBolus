import SwiftUI
import faBolusCore

/// Enter the cloud-follower credentials for the CGM failover sources. Non-secret fields persist to
/// UserDefaults (`GlucoseSourceConfig`); passwords/tokens go to the Keychain (`CredentialStore`).
/// Applied on the next launch (like the source/backend selection). Sensitive fields use SecureField.
struct CgmCredentialsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    // Dexcom Share (G6 / last-resort)
    @State private var shareUser = ""
    @State private var sharePass = ""
    @State private var shareRegion = "us"

    /// E7: the currently-selected fallback source's display name (nil if none chosen yet), for the
    /// "Test <name>" button label and the empty-state guidance.
    private var selectedSourceName: String? {
        guard let id = GlucoseSourceRegistry.selectedId() else { return nil }
        return GlucoseSourceRegistry.descriptor(id: id)?.name ?? id
    }

    /// E7: which sources the "Test" button exercises — ONLY the currently-selected fallback source (the
    /// one the app will actually use), never the whole set. Empty when no fallback is chosen yet. Pure so
    /// the selected-only contract is unit-testable without the SwiftUI view.
    ///
    /// W-04 (D-14) — KEEP-WITH-COMMENT: this helper has ZERO production call sites (the live Test flow
    /// observes `AppModel.glucoseSourceProbe` directly), but it is still exercised by
    /// `CgmSourceValidationTests.testExercisesOnlyTheSelectedSource`, which pins the selected-only
    /// contract. Deleting it (and `GlucoseSourceRegistry.make(id:)`) is the lower-value / higher-risk
    /// option under full-hardening scope; do NOT remove either without migrating those test call sites in
    /// the same change. Kept deliberately.
    static func sourcesToTest(selectedId: String?) -> [String] {
        guard let id = selectedId, !id.isEmpty else { return [] }
        return [id]
    }

    /// D-11: the set of source ids that have a dedicated config section in this view. Pinned by
    /// `CgmConfigSectionCopyGuardTests.everyRegistrySourceHasAConfigSection` to equal the full
    /// `GlucoseSourceRegistry` id set — adding a registry source without a section (or dropping one)
    /// turns that guard RED, so a source with a hard, non-obvious precondition can never become
    /// selectable with no explainer. G7 / HealthKit / xDrip App Group were the three that had none.
    static let configuredSectionSourceIds: Set<String> = {
        let ids: Set<String> = [
            "dexcom-share",
        ]
        // HealthKit ("healthkit") was removed from narrow `main` in Phase 5 (HEALTH-01) — see
        // dev/healthkit's REINTEGRATION.md. Nightscout ("nightscout") was removed from narrow
        // `main` in Phase 5 (HEALTH-02) — see dev/nightscout's REINTEGRATION.md. This set stays
        // equal to GlucoseSourceRegistry.enabled's id set (pinned by
        // CgmConfigSectionCopyGuardTests.everyRegistrySourceHasAConfigSection).
        return ids
    }()

    // MARK: - Test flow (change 3, D-13 UX): determinate, observes the live production source

    /// Outcome of observing the selected source's live production probe (`AppModel.
    /// glucoseSourceProbe`) for the "Test" flow — DETERMINATE: the caller (`AppModel.startCgmTest`)
    /// polls elapsed time on a timer and re-evaluates, rather than an indeterminate spinner.
    /// `.success` when a reading is already buffered — an already-buffered reading always wins, even
    /// past the timeout, so a late poll tick can never downgrade a real result to a timeout. `.timeout`
    /// once the window has elapsed with nothing, OR immediately if the source reports a hard `.error`
    /// (nothing to wait for — surfaced right away regardless of elapsed). `.waiting` otherwise.
    enum CgmTestOutcome: Equatable {
        case waiting
        case success(GlucoseSample)
        case timeout(detail: String?)
    }

    /// The pure Test-flow decision (change 3, D-13 UX) — kept pure and unit-testable like
    /// `sourcesToTest` (`CgmTestFlowStateTests`). See `CgmTestOutcome` for the priority order.
    static func testOutcome(latest: GlucoseSample?, status: GlucoseSourceStatus,
                             elapsed: TimeInterval, timeout: TimeInterval) -> CgmTestOutcome {
        if let latest { return .success(latest) }
        if case let .error(msg) = status { return .timeout(detail: msg) }
        if elapsed >= timeout { return .timeout(detail: nil) }
        return .waiting
    }

    /// The live production source's typed `connectionKind` (D-06), sourced from the running instance's
    /// probe — the Test-flow copy/window branch on THIS, never on `id`-string literals (D-09).
    private var probeKind: GlucoseConnectionKind? { model.glucoseSourceProbe?.connectionKind }

    // MARK: - Source-appropriate Test-flow copy (D-09), keyed on the typed connectionKind
    //
    // Pure/static so the per-category copy is unit-testable (`CgmTestFlowStateTests`) without the
    // SwiftUI view — the same discipline as `testOutcome`/`sourcesToTest`. `.localBLE` keeps the
    // already-correct confident BLE copy verbatim; `.cloudPoll`/`.localOnDevice` get their own
    // auth-network / on-device-sync framing and NEVER reuse the BLE "sensor wake cycle" language
    // (F-12). `nonisolated` so the guards are callable from a non-@MainActor test.

    nonisolated static func waitingHeadline(kind: GlucoseConnectionKind, sourceName: String) -> String {
        switch kind {
        case .localBLE:
            return "Waiting for the next Dexcom reading — up to ~5 min. Keep the Dexcom app running; you can leave this screen and we'll keep listening."
        case .cloudPoll:
            return "Checking your credentials and connection to \(sourceName)… this usually takes a few seconds."
        case .localOnDevice:
            return "Checking whether \(sourceName) is syncing readings on this device… this is usually near-instant."
        }
    }

    nonisolated static func timeoutHeadline(kind: GlucoseConnectionKind, sourceName: String, elapsedSeconds: Int) -> String {
        switch kind {
        case .localBLE:
            let minutes = max(1, elapsedSeconds / 60)
            return "No reading yet after \(minutes) min — make sure the Dexcom app is running; try toggling its Bluetooth."
        case .cloudPoll:
            return "No reading after \(max(1, elapsedSeconds))s from \(sourceName) — check your username/password and internet connection."
        case .localOnDevice:
            return "No reading yet from \(sourceName) — make sure the upstream app (e.g. xDrip or Eversense) is installed and actively syncing glucose on this device."
        }
    }

    private func waitingHeadline() -> String {
        let name = selectedSourceName ?? "the selected source"
        guard let kind = probeKind else {
            return "Waiting for a reading from \(name). You can leave this screen; we'll keep listening."
        }
        return Self.waitingHeadline(kind: kind, sourceName: name)
    }

    private func successHeadline() -> String {
        "✓ Received a reading from \(selectedSourceName ?? "the selected source")"
    }

    private func successDetail(_ sample: GlucoseSample) -> String {
        let age = Int(max(0, Date().timeIntervalSince(sample.date)))
        let ageStr = age < 60 ? "\(age)s ago" : "\(age / 60) min ago"
        let stale = GlucoseFreshness.isStale(sample.date) ? " · STALE" : ""
        // WR-03 gap closure (04-07): route through the display-unit funnel — reachable from mainline
        // Settings ("CGM credentials & testing"), not debug-gated.
        let bgUnit = AppSettings.shared.glucoseDisplayUnit
        let bgStr = "\(bgUnit.format(mgdl: sample.mgdl)) \(bgUnit == .mmol ? "mmol/L" : "mg/dL")"
        return "\(bgStr) \(sample.trend?.rawValue ?? "") · \(ageStr)\(stale)"
    }

    private func timeoutHeadline(elapsedSeconds: Int) -> String {
        let name = selectedSourceName ?? "the selected source"
        guard let kind = probeKind else {
            let minutes = max(1, elapsedSeconds / 60)
            return "No reading yet after \(minutes) min from \(name) — check the connection/credentials."
        }
        return Self.timeoutHeadline(kind: kind, sourceName: name, elapsedSeconds: elapsedSeconds)
    }

    private func elapsedLabel(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s elapsed" : "\(seconds / 60)m \(seconds % 60)s elapsed"
    }

    /// D-13/F-13: map a source's RAW error text (e.g. `SourceError.errorDescription`'s "HTTP 401",
    /// "Unexpected response") to source-aware, ACTIONABLE guidance — never surfacing a bare technical
    /// status/status-code to the operator. Keyed on the typed `connectionKind` for the fallback framing
    /// (a cloud source's "check your credentials/connection" vs an on-device source's "is the upstream
    /// app syncing"). Pure/`nonisolated` so it's unit-testable without the SwiftUI view.
    nonisolated static func actionableErrorCopy(_ raw: String, kind: GlucoseConnectionKind) -> String {
        let lower = raw.lowercased()
        if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized")
            || lower.contains("forbidden") {
            return "Sign-in was rejected — check your username and password for this source."
        }
        if lower.contains("http 5") || lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("network") || lower.contains("offline")
            || lower.contains("could not connect") || lower.contains("not connected to the internet") {
            return "Couldn't reach the service — check your internet connection, then try again."
        }
        if lower.contains("http 4") || lower.contains("unexpected response") || lower.contains("bad") {
            return "The service returned an unexpected response — check the site URL and your settings."
        }
        if lower.contains("invalid") || lower.contains("check settings") || lower.contains("not configured") {
            return "This source isn't fully configured — check its URL / region / credentials in the fields above."
        }
        // Fallback: NEVER echo the raw technical string; give category-appropriate next steps.
        switch kind {
        case .cloudPoll:     return "Couldn't get a reading — check your credentials and internet connection."
        case .localOnDevice: return "Couldn't get a reading — make sure the upstream app is installed and syncing on this device."
        case .localBLE:      return "Couldn't get a reading — make sure the official Dexcom app is running."
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $shareUser)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $sharePass)
                Picker("Region", selection: $shareRegion) {
                    Text("US").tag("us")
                    Text("Outside US").tag("ous")
                    // D-13: APAC region (writes "apac" → KnownShareServers.APAC / share.dexcom.jp,
                    // whose source-side mapping landed in Plan 03).
                    Text("Asia-Pacific (Japan)").tag("apac")
                }
            } header: {
                Text("Dexcom Share (last resort)")
            } footer: {
                Text("Your Dexcom account with Share enabled and uploading. Cloud-only and unreliable — a last-resort feed for G6.")
            }

            // D-11: HealthKit's config section (the one remaining source that previously had no
            // section) was removed with the source in Phase 5 (HEALTH-01) — see dev/healthkit's
            // REINTEGRATION.md. Nightscout's config section was removed with the source in
            // Phase 5 (HEALTH-02) — see dev/nightscout's REINTEGRATION.md. The G7 section was
            // removed with the source (Phase 1, Plan 03 — CGM-01/CGM-02); xDrip App Group's
            // section was removed with the source (Phase 1, Plan 01 — CGM-05); the LibreLinkUp
            // and Dexcom G6 sections/descriptors were removed with their sources (Phase 1,
            // Plan 02 — CGM-03/CGM-04, D-10).

            Section {
                Button {
                    save()
                    model.startCgmTest()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text(model.cgmTestInProgress ? "Testing…" : "Test \(selectedSourceName ?? "selected source")").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(model.cgmTestInProgress || selectedSourceName == nil)

                // Change 3 (D-13 UX): a DETERMINATE waiting state — a linear ProgressView with a
                // `value` (not the indeterminate spinner variant), an elapsed indicator, and explicit
                // SUCCESS/TIMEOUT terminal states. `model.cgmTestOutcome`/`cgmTestElapsedSeconds` are
                // AppModel-owned (not view @State), so this state SURVIVES navigating away and back.
                if let outcome = model.cgmTestOutcome {
                    switch outcome {
                    case .waiting:
                        VStack(alignment: .leading, spacing: 6) {
                            Text(waitingHeadline()).font(.subheadline)
                            ProgressView(value: model.cgmTestTimeoutSeconds > 0
                                         ? min(1, Double(model.cgmTestElapsedSeconds) / Double(model.cgmTestTimeoutSeconds)) : 0)
                            Text(elapsedLabel(seconds: model.cgmTestElapsedSeconds))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .success(let sample):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(successHeadline()).font(.subheadline)
                                Text(successDetail(sample)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    case .timeout(let detail):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(timeoutHeadline(elapsedSeconds: model.cgmTestElapsedSeconds)).font(.subheadline)
                                // D-13/F-13: humanize the raw source error (never a bare "HTTP 401").
                                if let detail {
                                    Text(Self.actionableErrorCopy(detail, kind: probeKind ?? .cloudPoll))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if selectedSourceName == nil {
                    Text("Pick a fallback source above, then test it here. Credentials save automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Credentials save automatically (applied the next time the app launches, like the fallback selection itself). **Test** observes the fallback source that's already running in the background, so a reading it already has shows instantly.")
            }
        }
        .navigationTitle("CGM credentials & testing")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        // E7: no Save button — leaving this sub-view persists whatever was entered (and Test / "read
        // transmitter ID" also save immediately), so credentials are never lost to a missed tap.
        .onDisappear(perform: save)
    }

    private func load() {
        shareUser = GlucoseSourceConfig.string("dexcomshare.username") ?? ""
        sharePass = CredentialStore.get(account: "dexcomshare.password") ?? ""
        shareRegion = GlucoseSourceConfig.string("dexcomshare.region") ?? "us"
    }

    private func save() {
        func trimmed(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        GlucoseSourceConfig.set(trimmed(shareUser), "dexcomshare.username")
        CredentialStore.set(trimmed(sharePass), account: "dexcomshare.password")
        GlucoseSourceConfig.set(shareRegion, "dexcomshare.region")
    }

}
