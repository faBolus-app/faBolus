import AppIntents
import Foundation

/// Write App Intent for a headless temp-rate Shortcuts action (999.2, D-01). Mirrors
/// `SetExerciseModeIntent`/`SetSleepModeIntent` (`ModeIntents.swift`) exactly: `openAppWhenRun = false`
/// keeps it silent, and it calls through the same `*Automation`-shaped gated orchestrator
/// (`TempRateAutomation`) rather than talking to `AppModel`/the backend directly.
///
/// `isDiscoverable` is left at its Apple-default `true` — the intent is discoverable as a Shortcuts
/// **action** with no `AppShortcutsProvider` entry required (06-RESEARCH Pattern 3). It is deliberately
/// **NOT** added to `FaBolusShortcuts.appShortcuts` (`StatusIntents.swift`) — no Siri voice phrase, per
/// D-01/D-07/§8-L7. That exclusion is regression-guarded by the L7 count test added in plan 06-02.
///
/// The `@Parameter` values below are UNCONSTRAINED — a Shortcut can pass any `Int` through a variable
/// (a fat-fingered value, a chained calculation, a shared macro). The real safety boundary is
/// `TempRateAutomation`'s `PumpControlBounds`-range validation (D-04 REVISED), NOT this parameter type;
/// see `TempRateAutomation.swift`'s header for the full gate order.
struct SetTempRateIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Temp Rate"
    static let description = IntentDescription(
        """
        Set a temporary basal rate on your Tandem pump (Mobi only, Control-IQ must be off). Accepts \
        0-250% for 15 minutes-72 hours — the same range as the official Tandem Mobi app. Use in a \
        Shortcuts macro; run manually in the app for a confirmed one-off change.
        """)
    static let openAppWhenRun = false

    @Parameter(title: "Percent")
    var percent: Int

    @Parameter(title: "Duration (minutes)")
    var durationMinutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set Temp Rate to \(\.$percent)% for \(\.$durationMinutes) minutes")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await TempRateAutomation.request(percent: percent, duration: durationMinutes)
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}
