import SwiftUI

#if FABOLUS_NUDGE
/// Smart Assist (faBolusNudge) settings, in their own submenu (like Child mode / Backup & restore /
/// Data & history) rather than an inline Settings section. All advisory-only.
struct SmartAssistSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Bolus guardrail", isOn: $settings.smartAssistEnabled)
                Toggle("Predictive-low alerts", isOn: $settings.hypoAlertsEnabled)
                NavigationLink { EatingNudgeSettingsView() } label: {
                    Label(settings.eatingNudgesEnabled ? "Eating nudges (on)" : "Eating nudges",
                          systemImage: "fork.knife")
                }
            } footer: {
                Text("**Advisory only** — never blocks or changes a dose. The bolus guardrail warns when a dose looks likely to cause a low or is stacking on active insulin. Predictive-low alerts warn in-app when a sustained low looks likely soon. Both off by default. Retrospective insights are under Data & History.")
            }
        }
        .navigationTitle("Smart Assist")
    }
}
#endif
