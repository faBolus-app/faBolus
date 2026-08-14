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

            Section("Delay Sleep mode") {
                Text("Want Sleep mode to switch on a little *after* your Sleep Focus starts?")
                    .font(.callout)
                Text("Option A — short delay (a few minutes)").font(.subheadline.bold())
                step(1, "Automation → **Focus → Sleep → When Turning On → Run Immediately** (turn off *Ask Before Running*).")
                step(2, "Add **Wait** (Scripting) and set the seconds, e.g. 300 = 5 min.")
                step(3, "Add **Set Sleep Mode = On**.")
                Label("iOS pauses the Wait step while your phone is locked, so delays longer than a few minutes may not fire. Keep this short, or use Option B below.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Option B — fixed-time delay (reliable, recommended for longer delays)").font(.subheadline.bold())
                step(1, "Automation → **Time of Day** → pick the time (e.g. 30 min after your usual bedtime), **Repeat Daily**, **Run Immediately** (*Ask Before Running* off).")
                step(2, "Add **Set Sleep Mode = On**.")
                Label("This is keyed to the clock, not the moment Sleep Focus starts, but runs reliably overnight. Pair either option with a matching wake-up automation running Set Sleep Mode = Off.", systemImage: "clock")
                    .font(.footnote).foregroundStyle(.secondary)
                Label("Your Tandem Mobi / Control-IQ has its own on-pump Sleep schedule, set on the pump. faBolus does not read or reimplement that schedule — this Shortcuts automation is an alternative to it, not a copy. Use the pump's built-in Sleep schedule **or** this automation, not both, or the two can conflict.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Build a one-tap macro") {
                Text("Combine several faBolus actions into one shortcut and put it on your Home Screen or in the Shortcuts widget:")
                    .font(.callout)
                step(1, "Shortcuts → **+** (new shortcut).")
                step(2, "Add **Set Exercise Mode = On**.")
                step(3, "Add **Set Temp Rate** and choose a percent (0–250%) and duration (15 min–72h) — the same range the pump and the official Tandem Mobi app allow. faBolus doesn't narrow this further; your pump's own **Basal Limit** (Delivery Limits) is the ceiling, and the pump rejects a rate that would exceed it.")
                step(4, "Name it (e.g. \"Going for a run\") → **Share → Add to Home Screen**, or add it to the **Shortcuts widget** / **Action Button** / **Back Tap**.")
                Label("Tapping it applies your **Set Exercise Mode** switch in the background — no confirmation, without opening the app — as long as you use fixed values and avoid *Ask Each Time* (which pauses to prompt).", systemImage: "bolt")
                    .font(.footnote).foregroundStyle(.secondary)
                // §13 / D-03: the Set-Temp-Rate disclosure below is insulin-affecting DRAFT copy, §13-pending —
                // it must pass §13 clinical review before any experimental distribution (BRANCHES.md §13). Its
                // job today is to state the build-inert truth: `TempRateAutomation.benchVerifiedDefault` ships
                // `false`, so `SetTempRateIntent` refuses every headless run ("pending saline-bench validation")
                // until the Phase-11 saline-bench flag flips. Display copy only — no gate depends on this string.
                Label("**Set Temp Rate isn't active yet.** It's pending saline-bench validation and will decline every run until a future faBolus update enables it — the other actions in the macro still run.", systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
                Label("Temp-rate options appear only on pumps/controllers that support them. Boluses are never available in Shortcuts.", systemImage: "hand.raised")
                    .font(.footnote).foregroundStyle(.secondary)
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
