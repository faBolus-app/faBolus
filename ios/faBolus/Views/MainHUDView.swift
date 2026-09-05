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
                        // Full-width alert/CTA bands stay full-width above the two-column region.
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
                                // 44×44 hit area; the glyph stays small.
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

                                        // Dose-affecting — no .hoverEffect / .keyboardShortcut.
                        if model.snapshot.connection == .bolusing && model.capabilities.supportsBolusCancel {
                            Button(role: .destructive) {
                                Task { await model.cancelBolus() }
                            } label: {
                                Label("Cancel bolus", systemImage: "stop.fill").font(.headline).frame(
                                    maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal)
                                .accessibilityLabel("Cancel bolus")
                        }

                        // Two-column: ring/pills/chart left, stats/details right. Double-frame
                        // centers the capped region (a single frame left-aligns on a 13" iPad).
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 14) {
                                StatusRingView(snapshot: model.snapshot, failover: model.failoverBadge)

                                StatusPillsView(snapshot: model.snapshot)

                                // Chart at the column's full width — never a clipped sub-fraction.
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

                        // Persistent re-entry when unpaired — no dismiss; stays until pairing exists.
                        if !model.hasStoredPairing {
                            NoPumpConnectedCard(model: model)
                        }

                        // Low Power Mode may delay background pump/CGM updates. Advisory only —
                        // never changes cadence and never gates a dose.
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
                                // 44×44 hit area; the glyph stays small.
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

                                        // Dose-affecting — no .hoverEffect / .keyboardShortcut.
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
        // Scale to the largest accessibility text size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
        // Mobi reject-at-pairing: observe at this root so it outlives the transient PairingSheet
        // (the sheet dismisses via `onDone()` without awaiting `connectWithCode`).
        .onChange(of: model.snapshot.pumpModel) { _, _ in model.rejectMobiIfDetected() }
    }

    /// `performControl`'s catch-all stores `error.localizedDescription`. Every other `lastError` in
    /// AppModel is already a human sentence; this maps only Foundation's raw "couldn't be completed
    /// (Domain error N)" / "domain#code" shapes. Curated strings pass through unchanged.
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

/// Persistent empty-state: skippers from first-run onboarding still land here and can open
/// `PairingSheet`. No dismiss control — stays until a pump is paired.
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

    /// Value string for a detail field id, or nil to skip the row (no data). `now` is the display
    /// instant supplied by the `TimelineView` in `body`, so the age-gated rows re-evaluate on the tick
    /// rather than waiting for the next pump read to mutate the snapshot.
    private func value(_ id: String, now: Date) -> String? {
        switch id {
        // `…IfRead` funnel, same reason as the reservoir/battery rows below: `iobUnits` is a
        // non-optional `0`, so a pump that never answered op-109 asserted a confident `0.00 U` of
        // active insulin here. A real 0.00 U still shows `0.00 U`; only never-reported shows "—".
        // Age-gated on `CalcInputFreshness.staleAfterIob` — the IOB dose gate's OWN window, not the CGM
        // one the reservoir/battery rows below use, so this row can never show a figure the bolus
        // calculator has already stopped trusting (`PumpSnapshot.iobUnitsIfFresh`).
        case "iob": return PumpValuePresentation.text(snapshot.iobUnitsIfFresh(now: now), format: "%.2f U")
        // Both rows go through the shared presentation helpers on the age-gated `…IfFresh(now:)` funnel,
        // so a read the pump never answered — OR answered once and has not re-answered inside the CGM
        // staleness window — shows "—" (like `carbRatio`/`isf` below) instead of a confident, and by now
        // possibly hours-old, number. Debug `tslim-reservoir-battery-zero` (presence) and
        // `pump-value-decay-to-unknown` (age). A genuine 0 still prints as 0 while fresh.
        case "reservoir":
            return ReservoirPresentation.make(units: snapshot.reservoirUnitsIfFresh(now: now)).valueText
        case "battery":
            // Reuse BatteryChargingPresentation (same as the battery pill); don't re-interpolate.
            let battery = BatteryChargingPresentation.make(
                percent: snapshot.batteryPercentIfFresh(now: now), charging: snapshot.batteryCharging)
            return battery.valueText
        case "cgm": return snapshot.cgmActive ? "Active" : "Inactive"
        case "lastBolus":
            guard let u = snapshot.lastBolusUnits, let d = snapshot.lastBolusDate else { return nil }
            return "\(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .named)))"
        // The three therapy rows age on `CalcInputFreshness.staleAfterTherapy` (the therapy dose gate's
        // own window) via the `…IfFresh(now:)` funnels. Those funnels also SUBSUME the pre-existing
        // `> 0` unread test — a carb ratio / correction factor / target of `0` is physically impossible,
        // so `0` has always meant unread here, and the funnel keeps that meaning. Hence `guard let`
        // replaces `guard … > 0` with no change to the unread case.
        case "carbRatio":
            return snapshot.carbRatioIfFresh(now: now).map { String(format: "%.0f g/U", $0) } ?? "—"
        // ISF + target through the display-unit funnel. Pump / BolusMath still get mg/dL Int.
        case "isf":
            guard let isf = snapshot.isfIfFresh(now: now) else { return "—" }
            let unit = AppSettings.shared.glucoseDisplayUnit
            guard AppSettings.shared.showGlucoseUnitLabels else { return unit.format(mgdl: isf) }
            return "\(unit.format(mgdl: isf)) mg/dL/U"
        case "target":
            guard let target = snapshot.targetBgIfFresh(now: now) else { return "—" }
            let unit = AppSettings.shared.glucoseDisplayUnit
            // Bare value when labels are hidden (ambient dashboard row).
            guard AppSettings.shared.showGlucoseUnitLabels else { return unit.format(mgdl: target) }
            return "\(unit.format(mgdl: target)) mg/dL"
        case "maxBolus": return String(format: "%.1f U", snapshot.maxBolusUnits)
        default: return nil
        }
    }

    var body: some View {
        // Same 20 s cadence as `StatusPillsView`, and for the same reason: the age-gated rows must be
        // able to decay to "—" on their own. Without a tick this card only re-rendered when the
        // snapshot VALUE changed — which is exactly what stops happening when a read goes quiet.
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            let rows: [(id: String, value: String)] = order.compactMap { id in
                value(id, now: ctx.date).map { (id, $0) }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                    row(AppSettings.detailFieldLabel(r.id), r.value, last: idx == rows.count - 1)
                }
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
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

/// Enter the pump's 6-digit (or legacy 16-character) pairing code, then connect + JPAKE-pair.
struct PairingSheet: View {
    @Bindable var model: AppModel
    let onDone: () -> Void
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Pump pairing code") {
                    // 6-digit (modern) or 16-char alphanumeric (pre-v7.7). asciiCapable so letters
                    // work; no autocapitalize/correct — the code is case-sensitive.
                    TextField("6-digit or 16-character code", text: $code)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title2.monospaced())
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
                    // No Mobi pairing instructions: this build rejects a Mobi at pairing, so telling
                    // the user how to pair one would be misleading. Generic t:slim copy stays.
                    Text(
                        "On the pump: Options → Device Settings → Bluetooth → Pair Device. Unpair the official t:connect app first — only one connection at a time.\n\nMost pumps show a 6-digit code. Older pumps (firmware before v7.7) show a longer 16-character code with letters and numbers — enter it exactly as shown (it is case-sensitive); faBolus pairs either way automatically."
                    )
                }
            }
            .navigationTitle("Connect to pump")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
        }
    }
}
