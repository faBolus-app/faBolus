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
        @Bindable var settings = settings   // local @Bindable for binding projection
        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if horizontalSizeClass == .regular {
                        // Full-width alert/CTA bands stay full-width, above the two-column region,
                        // on regular width too (D-04, UI-SPEC §3) — identical content/order to compact.
                        if !model.hasStoredPairing {
                            NoPumpConnectedCard(model: model)
                        }

                        if let eating = model.eatingNudge {
                            HStack {
                                Button {
                                    model.eatingNudgeActedOn()
                                    if !settings.phoneReadOnly { model.openBolusRequested = true }
                                } label: {
                                    Label(eating.message, systemImage: "fork.knife")
                                        .font(.subheadline).foregroundStyle(.orange)
                                }.buttonStyle(.plain)
                                .hoverEffect(.automatic)
                                .accessibilityLabel(eating.message)
                                .accessibilityHint("Opens bolus entry")
                                Spacer()
                                Button { model.dismissEatingNudge() } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .hoverEffect(.automatic)
                                .accessibilityLabel("Dismiss eating nudge")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        if model.shouldShowLowPowerAdvisory {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bolt.slash").foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(LowPowerAdvisory.message)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button { model.dismissLowPowerAdvisory() } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
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
                                HStack { ProgressView(); Text("Waiting for remote approval of \(String(format: "%.2f U", pending.units))…").font(.callout) }
                                    .accessibilityElement(children: .combine)
                                Button(role: .destructive) { model.cancelPendingApproval() } label: { Text("Cancel") }
                                    .hoverEffect(.automatic)
                                    .accessibilityLabel("Cancel pending approval")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                        }

                        // D-08 (UI-SPEC §9): "Cancel bolus" is a dose-affecting action (calls
                        // model.cancelBolus()) — deliberately gets NO .hoverEffect/.keyboardShortcut.
                        if model.snapshot.connection == .bolusing && model.capabilities.supportsBolusCancel {
                            Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                                Label("Cancel bolus", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal)
                            .accessibilityLabel("Cancel bolus")
                        }

                        // Two-column region (D-04, UI-SPEC §3): primary (left) = ring, pills,
                        // conditional lockout, chart block; secondary (right) = sleep/exercise card,
                        // conditional stats, pump details — in each column's today's vertical order.
                        // Capped at AppTheme.iPadDashboardRegionMaxWidth and centered via the
                        // double-frame idiom (RESEARCH Pattern 3 Pitfall — a single frame left-aligns
                        // on a 13" iPad).
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 14) {
                                StatusRingView(snapshot: model.snapshot, failover: model.failoverBadge)

                                StatusPillsView(snapshot: model.snapshot)

                                if settings.ciqLockoutCountdownEnabled,
                                   let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
                                       descriptor: model.snapshot.controllerDescriptor,
                                       controllerEnabled: model.snapshot.controlIQEnabled,
                                       lockoutStartDate: model.snapshot.lastAutoCorrectionDate, now: Date()),
                                   let availableAt = model.snapshot.lockoutUntilDate {
                                    LockoutCountdownBarView(fraction: fraction, availableAt: availableAt)
                                }

                                // Chart block renders at the column's FULL width — never a fixed
                                // sub-fraction, never clipped (D-04 non-negotiable chart protection).
                                VStack(spacing: 6) {
                                    GlucoseChartView(readings: model.glucoseHistory, iob: model.iobHistory,
                                                     boluses: model.bolusMarkers, windowHours: windowHours,
                                                     showGlucose: settings.showGlucoseAxis, showIOB: settings.showIOBAxis,
                                                     showBolusBars: settings.showBolusBars,
                                                     basalUnitsPerHour: model.snapshot.basalRateUnitsPerHour > 0
                                                         ? model.snapshot.basalRateUnitsPerHour : nil)
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
                                SleepExerciseAwarenessCard(snapshot: model.snapshot)

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

                        // Phase 09.4 (D-03): the persistent "no dead dashboard" re-entry — shown whenever
                        // there's no stored pairing, right after the status ring (first actionable content,
                        // no scroll). Unlike the eating-nudge/low-power cards below, this has NO dismiss
                        // control (`xmark.circle.fill`) — it must persist until `hasStoredPairing` becomes
                        // true, since it's the phase's literal "no dead dashboard" guarantee (ROADMAP SC1).
                        if !model.hasStoredPairing {
                            NoPumpConnectedCard(model: model)
                        }

                        if let eating = model.eatingNudge {
                            HStack {
                                // Tapping = "yes, I'm eating" → open Bolus + teach the on-device personalizer.
                                Button {
                                    model.eatingNudgeActedOn()
                                    if !settings.phoneReadOnly { model.openBolusRequested = true }
                                } label: {
                                    Label(eating.message, systemImage: "fork.knife")
                                        .font(.subheadline).foregroundStyle(.orange)
                                }.buttonStyle(.plain)
                                .hoverEffect(.automatic)
                                .accessibilityLabel(eating.message)
                                .accessibilityHint("Opens bolus entry")
                                Spacer()
                                Button { model.dismissEatingNudge() } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .hoverEffect(.automatic)
                                .accessibilityLabel("Dismiss eating nudge")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        // P16 F3 (WARN-ONLY): iOS Low Power Mode may delay background pump/CGM updates.
                        // Advisory pill only — dismissible per Low Power Mode episode; shown only while a
                        // source is connected. It never changes any cadence and never gates/blocks a dose.
                        if model.shouldShowLowPowerAdvisory {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bolt.slash").foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(LowPowerAdvisory.message)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button { model.dismissLowPowerAdvisory() } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
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
                                HStack { ProgressView(); Text("Waiting for remote approval of \(String(format: "%.2f U", pending.units))…").font(.callout) }
                                    .accessibilityElement(children: .combine)
                                Button(role: .destructive) { model.cancelPendingApproval() } label: { Text("Cancel") }
                                    .hoverEffect(.automatic)
                                    .accessibilityLabel("Cancel pending approval")
                            }
                            .padding().frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                        }

                        // D-08 (UI-SPEC §9): "Cancel bolus" is a dose-affecting action (calls
                        // model.cancelBolus()) — deliberately gets NO .hoverEffect/.keyboardShortcut.
                        if model.snapshot.connection == .bolusing && model.capabilities.supportsBolusCancel {
                            Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                                Label("Cancel bolus", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal)
                            .accessibilityLabel("Cancel bolus")
                        }

                        StatusPillsView(snapshot: model.snapshot).padding(.horizontal)

                        // T1-5 (D-01, D-07, D-08): a slim countdown card under the controlIQ/ciqZone pills —
                        // StatusPillsView is pill-shaped (too small for a bar). Gated on
                        // `ciqLockoutCountdownEnabled` (ON by default); fail-closed nil ⇒ card absent.
                        if settings.ciqLockoutCountdownEnabled,
                           let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
                               descriptor: model.snapshot.controllerDescriptor,
                               controllerEnabled: model.snapshot.controlIQEnabled,
                               lockoutStartDate: model.snapshot.lastAutoCorrectionDate, now: Date()),
                           let availableAt = model.snapshot.lockoutUntilDate {
                            LockoutCountdownBarView(fraction: fraction, availableAt: availableAt)
                                .padding(.horizontal)
                        }

                        // T1-9 (D-01, D-06 guardrail #4, D-07, D-08): the Sleep/Exercise awareness card
                        // — pure UI wiring of ControllerDescriptor.activityPresets. Fail-closed: absent
                        // unless a preset is actively selected by the pump's own controlIQMode AND the
                        // Smart-Assist toggle is on (never a "Normal mode" card).
                        SleepExerciseAwarenessCard(snapshot: model.snapshot).padding(.horizontal)

                        VStack(spacing: 6) {
                            GlucoseChartView(readings: model.glucoseHistory, iob: model.iobHistory,
                                             boluses: model.bolusMarkers, windowHours: windowHours,
                                             showGlucose: settings.showGlucoseAxis, showIOB: settings.showIOBAxis,
                                             showBolusBars: settings.showBolusBars,
                                             basalUnitsPerHour: model.snapshot.basalRateUnitsPerHour > 0
                                                 ? model.snapshot.basalRateUnitsPerHour : nil)
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
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(AppTheme.low).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("faBolus")
            .navigationBarTitleDisplayMode(.inline)
        }
        // N12 (Dynamic Type): let the dashboard scale up to the largest accessibility text size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
    }
}

/// Phase 09.4 (D-03) — the dashboard's persistent empty-state re-entry, shown whenever
/// `!model.hasStoredPairing`. This is the actual "no dead dashboard" guarantee (ROADMAP SC1): both skip
/// routes on the first-run `ConnectPumpOnboardingView` (D-01) leave a skipper here, always able to open
/// the SAME existing `PairingSheet`. Deliberately has NO dismiss control — it persists until a pump is
/// paired, unlike the neighboring eating-nudge/low-power cards.
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
        case "battery": return "\(snapshot.batteryPercent)%"
        case "cgm": return snapshot.cgmActive ? "Active" : "Inactive"
        case "lastBolus":
            guard let u = snapshot.lastBolusUnits, let d = snapshot.lastBolusDate else { return nil }
            return "\(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .named)))"
        case "carbRatio": return snapshot.carbRatio > 0 ? String(format: "%.0f g/U", snapshot.carbRatio) : "—"
        // Phase 04-01 (D-10): ISF + target route through the GlucoseUnit funnel so mmol users see
        // the correction factor and target in mmol/L too — mg/dL mode renders byte-identical to
        // before. The pump / BolusMath keep receiving mg/dL Int regardless (D-09); only this label
        // converts.
        case "isf":
            guard snapshot.isf > 0 else { return "—" }
            let unit = AppSettings.shared.glucoseDisplayUnit
            // WR-05 gap closure (04-07): standardize on "mmol/L/U" (the catalog/PumpWizard/Garmin
            // convention) instead of "mmol/L·U⁻¹" — same unit, was two different renderings.
            // Owner-requested toggle: bare value when labels are hidden (ambient dashboard row).
            guard AppSettings.shared.showGlucoseUnitLabels else { return unit.format(mgdl: snapshot.isf) }
            return "\(unit.format(mgdl: snapshot.isf)) \(unit == .mmol ? "mmol/L/U" : "mg/dL/U")"
        case "target":
            guard snapshot.targetBg > 0 else { return "—" }
            let unit = AppSettings.shared.glucoseDisplayUnit
            // Owner-requested toggle: bare value when labels are hidden (ambient dashboard row).
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
        // N12: each detail row reads as one element — "Active insulin, 1.23 U".
        .accessibilityElement(children: .combine)
        if !last { Divider().padding(.leading, 14) }
    }
}

/// Phase 09.15 T1-9 (D-01, D-06 guardrail #4, D-07, D-08) — pure UI wiring of the controller's OWN
/// activity presets (already Tandem-clinical-review-gated, §13) plus the pump-reported exercise
/// timer + sleep-schedule window. Card entirely absent when Control-IQ isn't in Sleep/Exercise right
/// now (`snapshot.ciqActivityPreset == nil`) — never a "Normal mode" card (empty-state rule) — or
/// when the Smart-Assist toggle (`ciqSleepExerciseAwarenessEnabled`, OFF by default, D-07) is off.
/// Mutual-exclusivity is structural: `ciqActivityPreset` selects exactly one preset (or none), so
/// this view's single `if let preset` branch can never render both Sleep and Exercise facts at
/// once. Fact lines each render independently (partial-state coverage, D-08): a missing datum
/// simply omits its own line, never blocks the rest of the card.
struct SleepExerciseAwarenessCard: View {
    let snapshot: PumpSnapshot
    @State private var settings = AppSettings.shared

    var body: some View {
        if settings.ciqSleepExerciseAwarenessEnabled, let preset = snapshot.ciqActivityPreset {
            let isSleep = preset.name == "Sleep"
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Reuses StatusPillsView's controlIQIcon choice exactly (moon.zzz.fill/figure.run)
                    // for visual consistency with the existing controlIQ pill.
                    Image(systemName: isSleep ? "moon.zzz.fill" : "figure.run")
                        .foregroundStyle(AppTheme.insulin)
                        .accessibilityHidden(true)
                    Text("\(preset.name) Activity is on").font(.subheadline).fontWeight(.semibold)
                }
                Text(SleepExerciseAwareness.targetAutoBolusLine(preset))
                    .font(.footnote).foregroundStyle(.secondary)
                if let threshold = SleepExerciseAwareness.suspendThresholdLine(preset) {
                    Text(threshold).font(.footnote).foregroundStyle(.secondary)
                }
                if isSleep {
                    // Sleep-only: the verbose window-schedule text (iPhone/Mac only, D-09.5).
                    if let window = snapshot.ciqSleepWindowLine {
                        Text(window).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let remaining = SleepExerciseAwareness.remainingLabel(seconds: snapshot.exerciseTimeRemainingSec) {
                    // Exercise-only: the countdown, never rendered alongside Sleep facts.
                    Text(remaining).font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            // N12: the whole card reads as one element (mirrors PumpDetailsCard's row idiom).
            .accessibilityElement(children: .combine)
        }
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
                            model.clearSavedPin(); code = ""; hadSavedPin = false
                        }
                    }
                }
                Section {
                    Button {
                        Task { await model.connectWithCode(code) }
                        onDone()
                    } label: { HStack { Spacer(); Text("Connect"); Spacer() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!PumpPairingCode.isValid(code))
                } footer: {
                    Text("On the pump: Options → Device Settings → Bluetooth → Pair Device (Mobi: on the charging pad, press the pump button twice; its PIN is behind the cartridge). Unpair the official t:connect app first — only one connection at a time.\n\nMost pumps show a 6-digit code. Older pumps (firmware before v7.7) show a longer 16-character code with letters and numbers — enter it exactly as shown (it is case-sensitive); faBolus pairs either way automatically.\n\nOn a Tandem Mobi the PIN never changes, so after connecting faBolus offers to save it and skip re-typing. To pair a different pump, edit the code above or Clear saved PIN.")
                }
            }
            .navigationTitle("Connect to pump")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
            .onAppear {
                if let pin = model.savedPin { code = pin; hadSavedPin = true }   // prefill saved Mobi PIN
            }
        }
    }
}
