import SwiftUI
import faBolusCore

/// Configure the eating-detection bolus nudge: which signals must agree, thresholds, confirmation delay,
/// and gates — with live guidance (≈ false alerts/day, % meals caught, time-to-alert, battery) so the
/// user can tune the trade-off. Advisory only; never doses. See MIGRATION.md / the Phase-5 plan.
struct EatingNudgeSettingsView: View {
    @State private var settings = AppSettings.shared

    private var cfg: Binding<EatingTriggerConfig> { $settings.eatingTriggerConfig }
    private var est: EatingTriggerEstimate { EatingTriggerEstimator.estimate(settings.eatingTriggerConfig) }

    var body: some View {
        Form {
            Section {
                Toggle("Eating nudges", isOn: $settings.eatingNudgesEnabled)
            } footer: {
                Text("**Advisory only** — reminds you to bolus when you're likely eating. Never doses, never blocks. Off by default.")
            }

            if settings.eatingNudgesEnabled {
                Section("How it decides") {
                    Picker("Mode", selection: cfg.mode) {
                        Text("CGM finds meal, wrist confirms").tag(EatingTriggerConfig.Mode.cgmThenAccel)
                        Text("Wrist + CGM (both, always on)").tag(EatingTriggerConfig.Mode.bothAlways)
                        Text("Wrist or CGM (either)").tag(EatingTriggerConfig.Mode.either)
                        Text("Wrist only").tag(EatingTriggerConfig.Mode.accelOnly)
                        Text("CGM only").tag(EatingTriggerConfig.Mode.cgmOnly)
                    }
                    Text(modeBlurb).font(.caption).foregroundStyle(.secondary)
                }

                // Live guidance — qualitative band + the numeric estimate underneath.
                Section("What to expect (estimate)") {
                    LabeledContent("False alerts") { Text("\(faBand) · ≈\(faNum)/day") }
                    LabeledContent("Catches", value: "~\(est.recallPercent)% of meals")
                    LabeledContent("Alerts", value: timeToAlert)
                    LabeledContent("Battery", value: est.battery.rawValue.capitalized)
                }

                Section("Sensitivity") {
                    if settings.eatingTriggerConfig.mode.usesAccel {
                        sliderRow("Wrist sensitivity", value: cfg.accelThreshold, range: 0.5...0.98, invert: true,
                                  help: "Higher sensitivity catches more meals but raises false alerts.")
                    }
                    if settings.eatingTriggerConfig.mode.usesCGM {
                        sliderRow("CGM sensitivity", value: cfg.cgmMealThreshold, range: 0.2...0.9, invert: true,
                                  help: "How readily a glucose rise counts as a meal.")
                    }
                }

                Section("Confirmation & gates") {
                    Stepper("Confirmation delay: \(settings.eatingTriggerConfig.confirmationDelaySeconds)s",
                            value: cfg.confirmationDelaySeconds, in: 0...300, step: 15)
                    Text("Longer = more confident / fewer false alerts, but a later nudge (less useful for pre-bolusing).")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Skip if bolused within: \(settings.eatingTriggerConfig.minMinutesSinceBolus) min",
                            value: cfg.minMinutesSinceBolus, in: 0...120, step: 5)
                    Toggle("Only at meal places (location)", isOn: cfg.locationEnabled)
                }
            }
        }
        .navigationTitle("Eating nudges")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: helpers

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           invert: Bool, help: String) -> some View {
        // "Sensitivity" is the inverse of the threshold — slide right = more sensitive = lower threshold.
        let sens = Binding<Double>(
            get: { invert ? (range.upperBound + range.lowerBound - value.wrappedValue) : value.wrappedValue },
            set: { value.wrappedValue = invert ? (range.upperBound + range.lowerBound - $0) : $0 })
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Slider(value: sens, in: range)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var faNum: String { String(format: "%.1f", est.falseAlertsPerDay) }
    private var faBand: String {
        switch est.falseAlertsPerDay { case ..<1: "Low"; case 1..<3: "Medium"; default: "High" }
    }
    private var timeToAlert: String {
        let m = est.typicalTimeToAlertSeconds / 60
        return m < 1 ? "~\(est.typicalTimeToAlertSeconds)s after eating" : "~\(m) min after eating starts"
    }
    private var modeBlurb: String {
        switch settings.eatingTriggerConfig.mode {
        case .cgmThenAccel: "Battery-smart: the CGM (already running) spots a likely meal, then the wrist sensor turns on briefly to confirm. Fewest false alerts and lowest battery — but a later nudge (a 'you ate & haven't bolused' catch)."
        case .bothAlways:   "The wrist sensor runs continuously and both signals must agree. Early + precise, but the highest battery use."
        case .either:       "Nudge as soon as either the wrist sensor or the CGM thinks you're eating. Earliest and most sensitive, but the most false alerts."
        case .accelOnly:    "Wrist motion only (needs the wrist sensor running). Early, no CGM needed."
        case .cgmOnly:      "CGM only — no wrist sensor, no extra battery. Later and a bit noisier (glucose rises aren't always meals)."
        }
    }
}
