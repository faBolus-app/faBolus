import AppIntents
import WidgetContent

// The Live Activity's buttons. Compiled into both the app and the widget extension: the extension draws
// the buttons, and iOS runs a `LiveActivityIntent` in the app's process, where `LiveActivityActions`
// hands the tap to the app's model. Each carries one tap: the action and the screen it was drawn on.

/// A step that may lead to insulin or changes the pump: every bolus step, and Clear on pump. iOS asks
/// for Face ID or the passcode first on a locked iPhone (verify on a device: docs/plans/live-activity-bolus.md).
struct LiveActivityActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Live Activity step" }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Tap") var tap: String

    init() {}

    init(_ tap: LiveActivityTap) {
        self.tap = tap.encoded
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.run(tap, unlocked: true)
        return .result()
    }
}

/// A step that sends no insulin and changes nothing on the pump but stopping a bolus: Cancel, leaving a
/// screen, the next alert, the chart's span. Cancel is never gated anywhere in the app.
struct LiveActivityStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Live Activity stop" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Tap") var tap: String

    init() {}

    init(_ tap: LiveActivityTap) {
        self.tap = tap.encoded
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.run(tap, unlocked: false)
        return .result()
    }
}
