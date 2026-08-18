import SwiftUI

/// Smart Assist settings, in their own submenu (like Child mode / Backup & restore /
/// Data & history) rather than an inline Settings section. All advisory-only.
///
/// 09.18a-03 (D-16): the whole-struct `#if FABOLUS_NUDGE` wrapper was removed — this submenu now
/// compiles and is reachable in BOTH the default (FABOLUS_NUDGE=0, CI) and local (FABOLUS_NUDGE=1)
/// builds. The LoopPowerPack features surfaced here are RUNTIME-toggle-gated, not compile-gated;
/// per-feature narrow-main compile exclusion is deferred to 09.16. Every symbol referenced below
/// (`AppSettings` flags, `EatingNudgeSettingsView`) lives in the app/faBolusCore and carries no
/// faBolusNudge-package dependency, so the view builds cleanly with the Nudge SDK stripped.
struct SmartAssistSettingsView: View {
    @Bindable var settings: AppSettings
    // WR-02: needed so the SiteAtlas tracker binds to the app's SHARED GlucoseHistoryStore
    // (`model.sharedHistoryStore`) instead of opening a second private ModelContainer.
    var model: AppModel

    // Phase 09.15 (D-07, plan 12): the generic Smart-Assist one-time explainer, fired on first ENABLE
    // of a limit/mode-framed surface (T1-8 or T1-9) — reuses the exact `showStackingGuardNotice`/
    // `hasAcknowledgedStackingGuardNotice` one-shot-ack idiom (`BolusEntryView.swift`), just with the
    // `AppSettings.shared.hasAcknowledgedCiqAwarenessNotice`/`.acknowledgeCiqAwarenessNotice()` flag the
    // tracer (09.15-01) already built. This is SEPARATE from, and in addition to, T1-8's own
    // feature-specific explainer (`hasAcknowledgedMaxBasalNotice`, already wired in `PumpControlView`).
    @State private var showCiqAwarenessNotice = false

    // Phase 09.18a-04 (D-16): the generic "About Smart Features" one-time explainer, fired on first
    // ENABLE of a Smart Features surface (currently SiteAtlas) — same one-shot-ack idiom as the CIQ
    // notice above, but with the D-16 `smartFeaturesNoticeAckAt` flag and the UI-SPEC copy.
    @State private var showSmartFeaturesNotice = false

    // Phase 09.18c-03 (D-13): the one-time PHI disclosure for the FoodFinder AI path — fired on first
    // ENABLE of the AI toggle (and re-enforced before the first AI call in FoodFinderAIEntryView). Same
    // one-shot-ack idiom, with the `hasAcknowledgedFoodFinderAINotice` flag and the verbatim UI-SPEC PHI
    // copy. This path is the ONLY one where PHI leaves the device, so the disclosure gates it explicitly.
    @State private var showFoodFinderAINotice = false

    var body: some View {
        Form {
            Section {
                NavigationLink { EatingNudgeSettingsView() } label: {
                    Label(settings.eatingNudgesEnabled ? "Eating nudges (on)" : "Eating nudges",
                          systemImage: "fork.knife")
                }
            } footer: {
                Text("**Advisory only** — never blocks or changes a dose. Eating nudges suggest a bolus when a meal looks likely. Off by default. Retrospective insights are under Data & History.")
            }

            // Phase 09.18a-04 (D-10/D-16/D-17): the SiteAtlas body-map tracker. Default-ON, runtime-gated
            // (D-16 — no compile `#if`). The toggle fires the generic one-time explainer on first enable;
            // when on, a NavigationLink reveals the tracker. `settings.siteAtlasEnabled` is referenced
            // literally here so SettingsReachabilityGuardTests (SC2) finds its catalog key.
            Section {
                Toggle("Site Atlas", isOn: Binding(
                    get: { settings.siteAtlasEnabled },
                    set: { newValue in
                        settings.siteAtlasEnabled = newValue
                        if newValue { presentSmartFeaturesNoticeIfNeeded() }
                    }))
                if settings.siteAtlasEnabled {
                    NavigationLink { SiteAtlasRootView(historyStore: model.sharedHistoryStore) } label: {
                        Label("Body-map site tracker", systemImage: "figure.stand")
                    }
                }
            } header: {
                Text("Smart Features")
            } footer: {
                Text("**Advisory only** — never blocks or changes a dose. Site Atlas tracks where you place infusion sets and CGM sensors and reminds you about reused spots. On by default.")
            }

            // Phase 09.18b (D-05/D-06/D-17): the GraphDetailView scrubbable-readout toggle. Default ON,
            // runtime-gated. This is display CONTEXT (read-only chart values), not a dose/limit surface,
            // so it deliberately does NOT fire the one-time Control-IQ explainer. `settings.graphDetailEnabled`
            // is a device-local display flag (not a SettingsCatalog row) — it gates the overlay in
            // GlucoseChartView; toggling off restores the chart exactly as before.
            Section {
                Toggle("Chart detail readout", isOn: $settings.graphDetailEnabled)
            } footer: {
                Text("**Advisory only** — never blocks or changes a dose. Tap and hold the glucose chart to read exact values at any time. On by default; turn off here.")
            }

            // Phase 09.18b (D-07/D-09/D-17): the heart-rate chart-context toggle. Default ON, off-able.
            // HR is display-only chart context — never a dose/meal input. Turning it OFF is the single
            // switch that (a) stops the phone's on-demand HealthKit HR query, (b) fires `hr_ctl` off to
            // the watch so it stops appending HR, and (c) hides the HR readout row entirely (not "—").
            // The set closure drives `model.setWantHeartRate` so the watch is told the instant it flips.
            Section {
                Toggle("Heart rate context", isOn: Binding(
                    get: { settings.heartRateContextEnabled },
                    set: { newValue in
                        settings.heartRateContextEnabled = newValue
                        model.setWantHeartRate(newValue)
                    }))
            } footer: {
                Text("**Heart rate is chart context only — never meal detection or dosing.** Off turns it off everywhere: the phone stops requesting it and your Garmin stops sending it.")
            }

            // Phase 09.18c-03 (D-12/D-13/D-17): the FoodFinder AI carb-estimate toggle. **Default OFF**
            // (opt-in) — this is the ONLY FoodFinder path where PHI (a food photo / description) leaves
            // the device, so enabling it fires the one-time PHI disclosure that MUST be acknowledged. The
            // AI estimate still reaches the dose ONLY through the shared "Add to carbs" → carbsText seam
            // (never auto-applied). Same D-07 idiom: bound Toggle whose setter fires the notice on enable.
            Section {
                Toggle("Estimate carbs with AI", isOn: Binding(
                    get: { settings.foodFinderAIEnabled },
                    set: { newValue in
                        settings.foodFinderAIEnabled = newValue
                        if newValue { presentFoodFinderAINoticeIfNeeded() }
                    }))
            } header: {
                Text("Food & carbs")
            } footer: {
                Text("Estimate carbs from a photo, voice, or description using an AI service you connect. This sends the photo/text to that provider — off the phone. **Off by default.** Advisory only — never blocks, changes, or suggests a dose.")
            }

            // Phase 09.15 (D-07, plan 12): the "Control-IQ awareness" subsection this plan adds — one
            // row per 09.15 feature toggle, bound directly to the `AppSettings` flags the tracer (09.15-01)
            // scaffolded, at the LOCKED D-07 defaults. This is the FIRST reachable Settings UI for every
            // one of these flags — prior plans (06/07/08/10/11) wired the flag itself but explicitly left
            // "not yet reachable via Settings UI" as a known gap; this section closes that gap for all of
            // them at once.
            Section {
                Toggle("Control-IQ state & status readouts", isOn: $settings.ciqStateReadoutsEnabled)
                Toggle("60-minute correction-lockout countdown", isOn: $settings.ciqLockoutCountdownEnabled)
                // T1-6 — NOT a toggle. The extended disable-Control-IQ warning always fires when a user
                // turns off Control-IQ (mirrors how StackingGuard disclosures aren't individually
                // toggleable either) — shown here as an informational, non-interactive row so the user
                // still sees it's part of Control-IQ awareness.
                HStack {
                    Label("Extended disable-Control-IQ warning", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Always on").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Extended disable-Control-IQ warning, always on, not adjustable")
                Toggle("\"% of configured max basal rate\" readout", isOn: Binding(
                    get: { settings.ciqMaxBasalReadoutEnabled },
                    set: { newValue in
                        settings.ciqMaxBasalReadoutEnabled = newValue
                        if newValue { presentCiqAwarenessNoticeIfNeeded() }
                    }))
                Toggle("Sleep / Exercise Activity awareness", isOn: Binding(
                    get: { settings.ciqSleepExerciseAwarenessEnabled },
                    set: { newValue in
                        settings.ciqSleepExerciseAwarenessEnabled = newValue
                        if newValue { presentCiqAwarenessNoticeIfNeeded() }
                    }))
                // T2-3/T2-1 — bench-gated placeholders (D-04/D-05): the toggle exists and can be flipped
                // (so the setting is ready the moment a bench flips the gate), but the feature itself
                // stays render-absent/inert pre-bench regardless of this toggle's state. No "coming
                // soon" copy — the row label is the same plain feature name every other row uses.
                Toggle("Control-IQ+ temporary basal rate", isOn: $settings.ciqPlusTempRateEnabled)
                Toggle("Control-IQ hourly/IOB limit flags", isOn: $settings.ciqCeilingFlagsEnabled)
            } header: {
                Text("Control-IQ awareness")
            } footer: {
                Text("**Informational only** — faBolus is not the pump and never changes Control-IQ or your insulin. These are read-only facts about what your pump is already doing.")
            }
        }
        .navigationTitle("Smart Assist")
        .alert("About Control-IQ awareness", isPresented: $showCiqAwarenessNotice) {
            Button("I understand") { AppSettings.shared.acknowledgeCiqAwarenessNotice() }
        } message: {
            Text("faBolus is not the pump and does not control Control-IQ. These are informational only and never change your insulin.")
        }
        .alert("About Smart Features", isPresented: $showSmartFeaturesNotice) {
            Button("I understand") { AppSettings.shared.acknowledgeSmartFeaturesNotice() }
        } message: {
            Text("These features are informational and advisory only. faBolus is not your pump and never changes your insulin or doses for you.")
        }
        // Phase 09.18c-03 (D-13): the verbatim PHI disclosure (UI-SPEC "FoodFinder — PHI disclosure").
        // Acknowledging here sets `foodFinderAINoticeAckAt`, which also unblocks the first AI call in
        // FoodFinderAIEntryView. Dismissing without "I understand" leaves the ack unset (the AI entry
        // surface then re-presents the disclosure before any call).
        .alert("Sending data to an AI provider", isPresented: $showFoodFinderAINotice) {
            Button("I understand") { AppSettings.shared.acknowledgeFoodFinderAINotice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turning this on sends your food photo/description to the AI provider you choose. That's health-adjacent data leaving your device. Only your carb estimate comes back — faBolus never doses automatically.")
        }
    }

    /// Fires the generic D-07 explainer exactly once ever, the first time the user enables EITHER
    /// limit/mode-framed surface (T1-8 or T1-9) — never on disable, never a second time.
    private func presentCiqAwarenessNoticeIfNeeded() {
        if !AppSettings.shared.hasAcknowledgedCiqAwarenessNotice {
            showCiqAwarenessNotice = true
        }
    }

    /// Fires the generic D-16 "About Smart Features" explainer exactly once ever, the first time the
    /// user enables a Smart Features surface (currently SiteAtlas) — never on disable, never twice.
    private func presentSmartFeaturesNoticeIfNeeded() {
        if !AppSettings.shared.hasAcknowledgedSmartFeaturesNotice {
            showSmartFeaturesNotice = true
        }
    }

    /// Fires the one-time PHI disclosure the first time the user enables the FoodFinder AI path — never
    /// on disable, never a second time. Until it is acknowledged, FoodFinderAIEntryView refuses to make
    /// an AI call (D-13).
    private func presentFoodFinderAINoticeIfNeeded() {
        if !AppSettings.shared.hasAcknowledgedFoodFinderAINotice {
            showFoodFinderAINotice = true
        }
    }
}
