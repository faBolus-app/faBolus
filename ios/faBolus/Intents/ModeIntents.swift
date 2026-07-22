import AppIntents
import Foundation

/// Write App Intents for activity/sleep automation (F1/F2). Unlike the read-only status intents,
/// these change the pump's Control-IQ mode — but only on a connected **Mobi** with Advanced control
/// on; otherwise they queue + remind (see `ModeAutomation`). They're designed to be dropped into a
/// **Shortcuts automation** ("When any Workout starts → Set Exercise Mode = On", "…ends → Off";
/// "When Sleep Focus turns on → Set Sleep Mode = On", "…off → Off").
///
/// `openAppWhenRun = false` keeps the automation silent; the switch is applied in the background when
/// the app is alive + connected, and reported honestly (applied / queued / reminder) in the dialog.

struct SetExerciseModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Exercise Mode"
    static let description = IntentDescription(
        "Turn the pump's Control-IQ Exercise mode on or off (Mobi only). Use in a Workout automation.")
    static let openAppWhenRun = false

    @Parameter(title: "On", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set Exercise Mode \(\.$enabled)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await ModeAutomation.request(.exercise, enabled: enabled)
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

struct SetSleepModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Mode"
    static let description = IntentDescription(
        "Turn the pump's Control-IQ Sleep mode on or off (Mobi only). Use in a Sleep Focus automation.")
    static let openAppWhenRun = false

    @Parameter(title: "On", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set Sleep Mode \(\.$enabled)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await ModeAutomation.request(.sleep, enabled: enabled)
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}
