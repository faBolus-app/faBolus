import AppIntents
import PhoneApp

// Shortcuts actions that turn the Live Activity on and off and say whether it's on. They set the settings
// screen's own switch through `AppModel.setLiveActivityEnabled`, so the screen, the model and the Live
// Activity agree whichever set it. None of them reaches the pump.

/// Where the intents find the app's model. The app delegate sets it at launch, before iOS runs an intent
/// that launched the app.
@MainActor
enum LiveActivityShortcuts {
    static var model: AppModel?

    static func requireModel() throws -> AppModel {
        guard let model else { throw ShortcutError.notReady }
        return model
    }
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource { "faBolus isn't ready yet. Try again." }
}

struct TurnOnLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource { "Turn On Live Activity" }
    static var description: IntentDescription? {
        IntentDescription("Shows faBolus's Live Activity. Opens faBolus, which iOS needs to start one.")
    }

    // ActivityKit starts a Live Activity only while the app is in the foreground (push-to-start needs a
    // push server, which faBolus doesn't have), so this opens the app. Run in the background it would only
    // save the setting, and the Live Activity would wait for the next time faBolus is opened.
    static var openAppWhenRun: Bool { true }
    @available(iOS 26, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        try LiveActivityShortcuts.requireModel().setLiveActivityEnabled(true)
        return .result()
    }
}

struct TurnOffLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource { "Turn Off Live Activity" }
    static var description: IntentDescription? { IntentDescription("Ends faBolus's Live Activity.") }

    // Ending a Live Activity works from the background, so this doesn't open the app.
    static var openAppWhenRun: Bool { false }
    @available(iOS 26, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        try LiveActivityShortcuts.requireModel().setLiveActivityEnabled(false)
        return .result()
    }
}

/// The settings switch, not whether iOS is showing one: with Live Activities turned off for faBolus in
/// iOS's Settings the switch can be on and none shows.
struct GetLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource { "Is Live Activity On" }
    static var description: IntentDescription? {
        IntentDescription("Whether faBolus's Show Live Activity setting is on.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let on = try LiveActivityShortcuts.requireModel().settings.liveActivityEnabled
        return .result(value: on, dialog: on ? "The Live Activity is on." : "The Live Activity is off.")
    }
}

/// The actions Shortcuts and Siri offer without any setup.
struct FaBolusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnLiveActivityIntent(),
            phrases: ["Turn on the \(.applicationName) Live Activity", "Show the \(.applicationName) Live Activity"],
            shortTitle: "Live Activity On", systemImageName: "rectangle.badge.checkmark")
        AppShortcut(
            intent: TurnOffLiveActivityIntent(),
            phrases: ["Turn off the \(.applicationName) Live Activity", "Hide the \(.applicationName) Live Activity"],
            shortTitle: "Live Activity Off", systemImageName: "rectangle.badge.xmark")
        AppShortcut(
            intent: GetLiveActivityIntent(),
            phrases: ["Is the \(.applicationName) Live Activity on"],
            shortTitle: "Live Activity Status", systemImageName: "questionmark.circle")
    }
}
