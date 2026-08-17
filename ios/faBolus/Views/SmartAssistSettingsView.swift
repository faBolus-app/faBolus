import SwiftUI

#if FABOLUS_NUDGE
/// Smart Assist (faBolusNudge) settings, in their own submenu (like Child mode / Backup & restore /
/// Data & history) rather than an inline Settings section. All advisory-only.
struct SmartAssistSettingsView: View {
    @Bindable var settings: AppSettings

    // Phase 09.15 (D-07, plan 12): the generic Smart-Assist one-time explainer, fired on first ENABLE
    // of a limit/mode-framed surface (T1-8 or T1-9) — reuses the exact `showStackingGuardNotice`/
    // `hasAcknowledgedStackingGuardNotice` one-shot-ack idiom (`BolusEntryView.swift`), just with the
    // `AppSettings.shared.hasAcknowledgedCiqAwarenessNotice`/`.acknowledgeCiqAwarenessNotice()` flag the
    // tracer (09.15-01) already built. This is SEPARATE from, and in addition to, T1-8's own
    // feature-specific explainer (`hasAcknowledgedMaxBasalNotice`, already wired in `PumpControlView`).
    @State private var showCiqAwarenessNotice = false

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
    }

    /// Fires the generic D-07 explainer exactly once ever, the first time the user enables EITHER
    /// limit/mode-framed surface (T1-8 or T1-9) — never on disable, never a second time.
    private func presentCiqAwarenessNoticeIfNeeded() {
        if !AppSettings.shared.hasAcknowledgedCiqAwarenessNotice {
            showCiqAwarenessNotice = true
        }
    }
}
#endif
