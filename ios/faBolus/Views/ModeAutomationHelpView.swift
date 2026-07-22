import SwiftUI

/// Step-by-step guide for wiring the Shortcuts automations that drive activity/sleep mode switching.
/// iOS doesn't let an app install a personal automation for you, so this walks the user through the
/// one-time setup in the Shortcuts app. The actions ("Set Exercise Mode", "Set Sleep Mode") are the
/// App Intents in `ModeIntents.swift`.
struct ModeAutomationHelpView: View {
    var body: some View {
        Form {
            Section {
                Text("faBolus exposes two Shortcuts actions — **Set Exercise Mode** and **Set Sleep Mode** — that you drop into an automation. iOS can't create the automation for you, so set it up once in the **Shortcuts** app.")
                    .font(.callout)
            }

            Section("Exercise mode on workout") {
                step(1, "Open **Shortcuts → Automation → +**.")
                step(2, "Choose **Workout**, pick **Any** (or specific types), **Is Started**, and **Run Immediately**.")
                step(3, "Add action **Set Exercise Mode**, set it to **On**.")
                step(4, "Make a second automation for **Is Ended → Set Exercise Mode = Off**.")
            }

            Section("Sleep mode on Sleep Focus") {
                step(1, "New automation → **Focus → Sleep → When Turning On → Run Immediately**.")
                step(2, "Add action **Set Sleep Mode = On**.")
                step(3, "Second automation for **When Turning Off → Set Sleep Mode = Off**.")
            }

            Section {
                Label("Auto-switching writes to the pump and works on **Tandem Mobi** only, with Advanced control enabled. On a t:slim X2 the action posts a reminder instead (enable reminders in the previous screen).", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                Label("The switch is applied in the background if faBolus is connected to the pump; if it isn't, the request waits up to 15 minutes for a reconnect, and you're reminded.", systemImage: "clock.arrow.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("Garmin can't trigger this automatically (Connect IQ has no activity-start event for a background app, and Garmin doesn't integrate with Apple Shortcuts). Switch modes from the pump, or from **Pump Control** in faBolus.")
            }
        }
        .navigationTitle("Set up automations")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(.indigo))
            Text(.init(text)).font(.callout)
        }
    }
}
