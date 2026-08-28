import SwiftUI
import faBolusCore
import faBolusDesign

/// Dashboard tab: modern glucose chart + status ring + HUD pills, then a scrollable details
/// section with everything sourced from the pump. Connection lives in the toolbar.
struct DashboardView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var windowHours = 3
    private let windows = [3, 6, 12, 24]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var settings = settings  // local @Bindable for binding projection
        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if horizontalSizeClass == .regular {
                        // Full-width alert/CTA bands stay full-width, above the two-column region,
                        // on regular width too — identical content/order to compact.
                        if !model.hasStoredPairing {
                            NoPumpConnectedCard(model: model)
                        }

                        if model.shouldShowLowPowerAdvisory {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bolt.slash").foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(LowPowerAdvisory.message)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button {
                                    model.dismissLowPowerAdvisory()
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                // The icon alone is ~24pt — pad the BUTTON's own hit area to Apple's
                                // 44×44pt minimum (the visible glyph stays its original small size, only the
                                // tappable region grows) so a low-vision/motor-impaired user can reliably hit it.
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .buttonStyle(.plain)
                                .hoverEffect(.automatic)
                                .accessibilityLabel("Dismiss low power notice")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        AlertsBannerView(model: model)

                        if let pending = model.pendingApproval {
                            VStack(spacing: 6) {
                                HStack {
                                    ProgressView()
                                    Text("Waiting for remote approval of \(String(format: "%.2f U", pending.units))…")
                                        .font(.callout)
                                }
                                .accessibilityElement(children: .combine)
                                Button(role: .destructive) {
                                    model.cancelPendingApproval()
                                } label: {
                                    Text("Cancel")
                                }
                                .hoverEffect(.automatic)
                                .accessibilityLabel("Cancel pending approval")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                        }

                        // "Cancel bolus" is a dose-affecting action (calls model.cancelBolus()) —
                        // deliberately gets NO .hoverEffect/.keyboardShortcut.
                        if model.snapshot.connection == .bolusing && model.capabilities.supportsBolusCancel {
                            Button(role: .destructive) {
                                Task { await model.cancelBolus() }
                            } label: {
                                Label("Cancel bolus", systemImage: "stop.fill").font(.headline).frame(
                                    maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal)
                                .accessibilityLabel("Cancel bolus")
                        }

                        // Two-column region: primary (left) = ring, pills, conditional lockout,
                        // chart block; secondary (right) = sleep/exercise card, conditional stats,
                        // pump details — in each column's compact-layout vertical order. Capped at
                        // AppTheme.iPadDashboardRegionMaxWidth and centered via the double-frame
                        // idiom (a single frame left-aligns on a 13" iPad).
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 14) {
                                StatusRingView(snapshot: model.snapshot, failover: model.failoverBadge)

                                StatusPillsView(snapshot: model.snapshot)

                                // Chart block renders at the column's FULL width — never a fixed
                                // sub-fraction, never clipped.
                                VStack(spacing: 6) {
                                    GlucoseChartView(
                                        readings: model.glucoseHistory, iob: model.iobHistory,
                                        boluses: model.bolusMarkers, windowHours: windowHours,
                                        showGlucose: settings.showGlucoseAxis, showIOB: settings.showIOBAxis,
                                        showBolusBars: settings.showBolusBars)
                                    Picker("Window", selection: $windowHours) {
                                        ForEach(windows, id: \.self) { Text("\($0)h").tag($0) }
                                    }.pickerStyle(.segmented)
                                    HStack(spacing: 16) {
                                        Toggle("Glucose", isOn: $settings.showGlucoseAxis)
                                        Toggle("IOB", isOn: $settings.showIOBAxis)
                                        Toggle("Bolus", isOn: $settings.showBolusBars)
                                    }.font(.caption).toggleStyle(.button).controlSize(.small)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)

                            VStack(spacing: 14) {
                                if settings.showStats {
                                    StatsCardView(history: model.glucoseHistory)
                                }

                                PumpDetailsCard(snapshot: model.snapshot)
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                        .frame(maxWidth: AppTheme.iPadDashboardRegionMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                    } else {
                        // Above the fold: glucose ring + the four status pills + the chart. Connection
                        // and Garmin setup live in the Settings tab now (not the toolbar).
                        StatusRingView(snapshot: model.snapshot, failover: model.failoverBadge)

                        // Persistent "no dead dashboard" re-entry — shown whenever there's no stored
                        // pairing, right after the status ring (first actionable content, no scroll).
                        // Unlike the low-power card below, this has NO dismiss control
                        // (`xmark.circle.fill`) — it must persist until `hasStoredPairing` becomes true.
                        if !model.hasStoredPairing {
                            NoPumpConnectedCard(model: model)
                        }

                        // iOS Low Power Mode may delay background pump/CGM updates. Advisory pill
                        // only — dismissible per Low Power Mode episode; shown only while a source is
                        // connected. It never changes any cadence and never gates/blocks a dose.
                        if model.shouldShowLowPowerAdvisory {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bolt.slash").foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(LowPowerAdvisory.message)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button {
                                    model.dismissLowPowerAdvisory()
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                // The icon alone is ~24pt — pad the BUTTON's own hit area to Apple's
                                // 44×44pt minimum (the visible glyph stays its original small size, only the
                                // tappable region grows) so a low-vision/motor-impaired user can reliably hit it.
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .buttonStyle(.plain)
                                .hoverEffect(.automatic)
                                .accessibilityLabel("Dismiss low power notice")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        AlertsBannerView(model: model)

                        if let pending = model.pendingApproval {
                            VStack(spacing: 6) {
                                HStack {
                                    ProgressView()
                                    Text("Waiting for remote approval of \(String(format: "%.2f U", pending.units))…")
                                        .font(.callout)
                                }
                                .accessibilityElement(children: .combine)
                                Button(role: .destructive) {
                                    model.cancelPendingApproval()
                                } label: {
                                    Text("Cancel")
                                }
                                .hoverEffect(.automatic)
                                .accessibilityLabel("Cancel pending approval")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                        }

                        // "Cancel bolus" is a dose-affecting action (calls model.cancelBolus()) —
                        // deliberately gets NO .hoverEffect/.keyboardShortcut.
                        if model.snapshot.connection == .bolusing && model.capabilities.supportsBolusCancel {
                            Button(role: .destructive) {
                                Task { await model.cancelBolus() }
                            } label: {
                                Label("Cancel bolus", systemImage: "stop.fill").font(.headline).frame(
                                    maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal)
                                .accessibilityLabel("Cancel bolus")
                        }

                        StatusPillsView(snapshot: model.snapshot).padding(.horizontal)

                        VStack(spacing: 6) {
                            GlucoseChartView(
                                readings: model.glucoseHistory, iob: model.iobHistory,
                                boluses: model.bolusMarkers, windowHours: windowHours,
                                showGlucose: settings.showGlucoseAxis, showIOB: settings.showIOBAxis,
                                showBolusBars: settings.showBolusBars)
                            Picker("Window", selection: $windowHours) {
                                ForEach(windows, id: \.self) { Text("\($0)h").tag($0) }
                            }.pickerStyle(.segmented)
                            HStack(spacing: 16) {
                                Toggle("Glucose", isOn: $settings.showGlucoseAxis)
                                Toggle("IOB", isOn: $settings.showIOBAxis)
                                Toggle("Bolus", isOn: $settings.showBolusBars)
                            }.font(.caption).toggleStyle(.button).controlSize(.small)
                        }
                        .padding(.horizontal)

                        // Opt-in statistics card (Settings → Display). Hidden by default.
                        if settings.showStats {
                            StatsCardView(history: model.glucoseHistory)
                        }

                        // Scroll target: everything else from the pump.
                        PumpDetailsCard(snapshot: model.snapshot).padding(.horizontal)
                    }

                    if let err = model.lastError {
                        Label(Self.humanizedDashboardError(err), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(AppTheme.low).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("faBolus")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Dynamic Type: let the dashboard scale up to the largest accessibility text size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
        // Reject-at-pairing observer, anchored at DashboardView's root so it OUTLIVES the
        // transient `PairingSheet` (the sheet dismisses immediately via `onDone()` without awaiting
        // `connectWithCode`, so an observer inside its button action never fires). Reacts to the
        // typed pump-model identity the instant the protected discovery callback
        // (`TandemBackend.swift`, unedited) sets it; the shared helper
        // (`AppModel+MobiReject.swift`) decides + tears down via the existing public
        // `disconnect()`/`forgetPairing()`.
        .onChange(of: model.snapshot.pumpModel) { _, _ in model.rejectMobiIfDetected() }
    }

    /// `AppModel.performControl`'s catch-all (byte-guarded — not editable here) sets `lastError =
    /// error.localizedDescription` on any pump-control failure. Every OTHER `lastError` assignment in
    /// AppModel is already a curated, human sentence ("Bolus sent but outcome is unknown…", "Nothing to
    /// revert…", …) — this maps ONLY the one recognizable raw shape Foundation emits for an `Error` that
    /// doesn't conform to `LocalizedError` (the "couldn't be completed. (<Domain> error <code>.)"
    /// boilerplate, or a bare NSError "domain#code" token) to one plain sentence. Any other string
    /// (including every curated one above) passes through byte-identical.
    private static func humanizedDashboardError(_ raw: String) -> String {
        let looksRaw =
            raw.range(
                of: #"couldn.t be completed\. \([^)]*error -?\d+\.?\)"#, options: [.regularExpression, .caseInsensitive]
            ) != nil
            || raw.range(of: #"^\S+#-?\d+\s"#, options: .regularExpression) != nil
            || raw.contains("Error Domain=")
        return looksRaw ? "Something went wrong completing that action — try again." : raw
    }
}

/// The dashboard's persistent empty-state re-entry, shown whenever `!model.hasStoredPairing`.
/// This is the "no dead dashboard" guarantee: both skip routes on the first-run
/// `ConnectPumpOnboardingView` leave a skipper here, always able to open the SAME existing
/// `PairingSheet`. Deliberately has NO dismiss control — it persists until a pump is paired,
/// unlike the neighboring low-power card.
private struct NoPumpConnectedCard: View {
    @Bindable var model: AppModel
    @State private var showPairing = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2).foregroundStyle(.secondary)
            Text("No pump connected").font(.headline)
            Text("Connect your pump to see glucose and give a bolus.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showPairing = true
            } label: {
                Text("Connect a pump").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .hoverEffect(.automatic)
        }
        .padding().frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .sheet(isPresented: $showPairing) { PairingSheet(model: model) { showPairing = false } }
    }
}

/// Card listing everything sourced from the pump (scroll target for "more details"). The rows shown
/// and their order come from `AppSettings.detailsOrder` (customizable in Settings → Customize details).
struct PumpDetailsCard: View {
    let snapshot: PumpSnapshot
    private var order: [String] { AppSettings.shared.detailsOrder }

    /// Value string for a detail field id, or nil to skip the row (no data).
    private func value(_ id: String) -> String? {
        switch id {
        case "iob": return String(format: "%.2f U", snapshot.iobUnits)
        case "reservoir": return "\(Int(snapshot.reservoirUnits)) U"
        case "battery":
            // Reuse BatteryChargingPresentation for the glyph/text decision (never re-derived
            // inline), same convention as StatusPillsView.pillFor("battery"); not-charging renders
            // identically. Consume the centralized `valueText` instead of re-interpolating the
            // "N% · Charging" string here.
            let battery = BatteryChargingPresentation.make(
                percent: snapshot.batteryPercent, charging: snapshot.batteryCharging)
            return battery.valueText
        case "cgm": return snapshot.cgmActive ? "Active" : "Inactive"
        case "lastBolus":
            guard let u = snapshot.lastBolusUnits, let d = snapshot.lastBolusDate else { return nil }
            return "\(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .named)))"
        case "carbRatio": return snapshot.carbRatio > 0 ? String(format: "%.0f g/U", snapshot.carbRatio) : "—"
        // ISF + target route through the GlucoseUnit funnel so mmol users see the correction
        // factor and target in mmol/L too. The pump / BolusMath keep receiving mg/dL Int
        // regardless; only this label converts.
        case "isf":
            guard snapshot.isf > 0 else { return "—" }
            let unit = AppSettings.shared.glucoseDisplayUnit
            // Standardize on "mmol/L/U" (the catalog/PumpWizard/Garmin convention) instead of
            // "mmol/L·U⁻¹" — same unit, two different renderings. Bare value when labels are
            // hidden (ambient dashboard row).
            guard AppSettings.shared.showGlucoseUnitLabels else { return unit.format(mgdl: snapshot.isf) }
            return "\(unit.format(mgdl: snapshot.isf)) \(unit == .mmol ? "mmol/L/U" : "mg/dL/U")"
        case "target":
            guard snapshot.targetBg > 0 else { return "—" }
            let unit = AppSettings.shared.glucoseDisplayUnit
            // Bare value when labels are hidden (ambient dashboard row).
            guard AppSettings.shared.showGlucoseUnitLabels else { return unit.format(mgdl: snapshot.targetBg) }
            return "\(unit.format(mgdl: snapshot.targetBg)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
        case "maxBolus": return String(format: "%.1f U", snapshot.maxBolusUnits)
        default: return nil
        }
    }

    var body: some View {
        let rows: [(id: String, value: String)] = order.compactMap { id in
            value(id).map { (id, $0) }
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                row(AppSettings.detailFieldLabel(r.id), r.value, last: idx == rows.count - 1)
            }
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func row(_ title: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 10)
        // Each detail row reads as one element — "Active insulin, 1.23 U".
        .accessibilityElement(children: .combine)
        if !last { Divider().padding(.leading, 14) }
    }
}

/// Enter the pump's 6-digit pairing code, then connect + JPAKE-pair. A saved Mobi PIN (if any) is
/// prefilled; you can edit it to pair a different pump, or clear it. Saving is *offered after
/// connecting* once we recognize a Mobi (see AppModel.savePinPrompt) — not decided up front.
struct PairingSheet: View {
    @Bindable var model: AppModel
    let onDone: () -> Void
    @State private var code = ""
    @State private var hadSavedPin = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Pump pairing code") {
                    // Accepts a 6-digit code (modern pumps) OR a 16-character letters+numbers code
                    // (older pumps, pre-v7.7). The app detects which and pairs accordingly — no toggle.
                    // asciiCapable (not numberPad) so the legacy alphanumeric code can be entered; no
                    // autocapitalization/autocorrect because the code is case-sensitive.
                    TextField("6-digit or 16-character code", text: $code)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title2.monospaced())
                    if hadSavedPin {
                        Button("Clear saved PIN", role: .destructive) {
                            model.clearSavedPin()
                            code = ""
                            hadSavedPin = false
                        }
                    }
                }
                Section {
                    Button {
                        Task { await model.connectWithCode(code) }
                        onDone()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Connect")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!PumpPairingCode.isValid(code))
                } footer: {
                    // Mobi-specific pairing instruction ("on the charging pad, press the pump button
                    // twice; its PIN is behind the cartridge") and Mobi-specific saved-PIN explanation
                    // are trimmed — this build rejects a Mobi at pairing, so instructing users how to
                    // pair one it will then reject was misleading. The generic t:slim pairing
                    // instruction and the (pump-agnostic) saved-PIN affordance stay, unchanged in
                    // behavior.
                    Text(
                        "On the pump: Options → Device Settings → Bluetooth → Pair Device. Unpair the official t:connect app first — only one connection at a time.\n\nMost pumps show a 6-digit code. Older pumps (firmware before v7.7) show a longer 16-character code with letters and numbers — enter it exactly as shown (it is case-sensitive); faBolus pairs either way automatically.\n\nIf faBolus has a saved PIN for this pump, it's prefilled here to skip re-typing. To pair a different pump, edit the code above or Clear saved PIN."
                    )
                }
            }
            .navigationTitle("Connect to pump")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
            .onAppear {
                if let pin = model.savedPin {
                    code = pin
                    hadSavedPin = true
                }
            }
        }
    }
}
