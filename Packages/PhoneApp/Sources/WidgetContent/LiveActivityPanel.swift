import Foundation

/// The Live Activity's controls: a picture of the app's bolus and alert screens (`LiveActivityFlow`),
/// carried in each update. The app decides everything; the views only draw this and send taps back. Every
/// tap names the screen it was drawn on, and the app ignores one from any screen but its current one, so a
/// picture that is out of date (an update still on its way, or one drawn before the app relaunched) never
/// acts.
public struct LiveActivityPanel: Codable, Sendable, Hashable {
    /// The screen's ID, new for each screen. Unique to one run of the app.
    public var screen: String
    public var view: Screen

    public init(screen: String, view: Screen) {
        self.screen = screen
        self.view = view
    }

    public enum Screen: Codable, Sendable, Hashable {
        /// The glucose card, with its bottom row.
        case idle(IdleButton)
        case entry(Entry)
        /// Whether to correct from the glucose, or to include a stale reading, each answer naming its dose.
        case question(Question)
        /// The dose and the 1 → 2 → 3 confirm.
        case review(Review)
        /// Something about the pump the phone asks the user to confirm before the dose goes.
        case confirm(Confirm)
        case result(Result)
        /// One pump alert.
        case alert(AlertCard)
    }

    /// The card's bolus button.
    public enum IdleButton: Codable, Sendable, Hashable {
        /// Bolusing from the Live Activity is off, or read-only: no button.
        case none
        case bolus
        /// A bolus can't start now, and why, in a few words.
        case unavailable(String)
        /// A bolus is going, from any surface.
        case cancel
        case cancelling
    }

    public struct Entry: Codable, Sendable, Hashable {
        public enum Mode: String, Codable, Sendable {
            case units, carbs
            /// The calculator with carbs off on the pump: food entered as insulin units.
            case food
        }
        public var mode: Mode
        /// "1.25 U" or "30 g".
        public var value: String
        public var canDecrease: Bool
        public var canIncrease: Bool
        /// The calculator's dose for a calculator entry ("2.35 U", "2.35 U or 2.00 U"), or why there is none.
        public var preview: String?
        /// What the dose depends on ("Correction asked next", "Stale CGM: carbs only").
        public var message: String?
        public var canReview: Bool

        public init(
            mode: Mode, value: String, canDecrease: Bool, canIncrease: Bool, preview: String? = nil,
            message: String? = nil, canReview: Bool
        ) {
            self.mode = mode
            self.value = value
            self.canDecrease = canDecrease
            self.canIncrease = canIncrease
            self.preview = preview
            self.message = message
            self.canReview = canReview
        }
    }

    public struct Question: Codable, Sendable, Hashable {
        /// "BG 180 mg/dL".
        public var title: String
        /// "above target 110 mg/dL", "Stale CGM · 9 min ago".
        public var detail: String
        /// "Add a correction?", "Reduce the bolus?", "Include it?".
        public var ask: String
        /// The first answer and its whole dose ("Corrected", "2.35 U").
        public var yes: String
        public var yesUnits: String
        /// The second ("Carbs only", "2.00 U").
        public var no: String
        public var noUnits: String

        public init(
            title: String, detail: String, ask: String, yes: String, yesUnits: String, no: String, noUnits: String
        ) {
            self.title = title
            self.detail = detail
            self.ask = ask
            self.yes = yes
            self.yesUnits = yesUnits
            self.no = no
            self.noUnits = noUnits
        }
    }

    public struct Review: Codable, Sendable, Hashable {
        /// "2.35 U".
        public var units: String
        /// A calculator dose's parts: "2.00 food + 0.35 correction".
        public var split: String?
        /// How many of 1, 2, 3 have been tapped in order.
        public var taps: Int
        /// When the review stops being sent; the view counts down to it.
        public var expiresAt: Date
        /// The review expired: it can only be started over.
        public var expired: Bool

        public init(units: String, split: String? = nil, taps: Int, expiresAt: Date, expired: Bool = false) {
            self.units = units
            self.split = split
            self.taps = taps
            self.expiresAt = expiresAt
            self.expired = expired
        }
    }

    public struct Confirm: Codable, Sendable, Hashable {
        /// "Low insulin", or "Confirm" for more than one.
        public var title: String
        public var message: String
        /// "Go on: 2.35 U".
        public var goOn: String

        public init(title: String, message: String, goOn: String) {
            self.title = title
            self.message = message
            self.goOn = goOn
        }
    }

    public struct Result: Codable, Sendable, Hashable {
        public enum Tone: String, Codable, Sendable {
            /// Still going: "Sending…", "Delivering…".
            case working
            /// "Delivered".
            case good
            /// "Stopped", "Outcome unknown".
            case caution
            /// "Not delivered", "Pump refused".
            case bad
        }
        public enum Button: String, Codable, Sendable {
            /// It may still deliver: it can be cancelled.
            case cancel
            case cancelling
            /// Settled: back to the card.
            case done
        }
        public var headline: String
        public var tone: Tone
        /// "2.35 U delivered", or the phone's reason.
        public var line: String?
        public var button: Button
        /// A cancel the pump hasn't answered: "No answer yet. To stop it now, use the pump."
        public var note: String?
        /// The result in a few characters, for the compact view and the Mac's menu bar ("2.00 U", "Stopped"),
        /// drawn after an icon for its tone.
        public var compact: String?

        public init(
            headline: String, tone: Tone, line: String? = nil, button: Button, note: String? = nil,
            compact: String? = nil
        ) {
            self.headline = headline
            self.tone = tone
            self.line = line
            self.button = button
            self.note = note
            self.compact = compact
        }
    }

    public struct AlertCard: Codable, Sendable, Hashable {
        public var title: String
        public var body: String
        public var critical: Bool
        /// "1 of 3".
        public var position: String?
        /// The session says the pump can clear it remotely, and it isn't a malfunction: what the watch offers.
        public var canClear: Bool
        /// The last clear's result: "Clearing…", "Pump didn't clear it".
        public var note: String?

        public init(
            title: String, body: String, critical: Bool, position: String? = nil, canClear: Bool, note: String? = nil
        ) {
            self.title = title
            self.body = body
            self.critical = critical
            self.position = position
            self.canClear = canClear
            self.note = note
        }
    }
}

/// The pump alerts, for the card's row and for CarPlay and the Watch: the most severe first.
public struct LiveActivityAlerts: Codable, Sendable, Hashable {
    public var topTitle: String
    public var topCritical: Bool
    public var count: Int

    public init(topTitle: String, topCritical: Bool, count: Int) {
        self.topTitle = topTitle
        self.topCritical = topCritical
        self.count = count
    }
}

/// What a Live Activity button asks the app to do.
public enum LiveActivityAction: Codable, Sendable, Hashable {
    case startBolus
    case switchMode
    /// One step of the phone's increment, or a coarse step (1 U, 10 g).
    case adjust(up: Bool, coarse: Bool)
    case review
    /// The question's first answer (correct, reduce, include) or its second (no correction).
    case answer(yes: Bool)
    /// 1, 2 or 3 of the confirm.
    case tap(Int)
    /// Go on from a confirmation the phone asked: back to the 1 → 2 → 3 confirm with it.
    case goOn
    /// The screen before.
    case back
    /// Back to the card: ✕, Done.
    case close
    /// Stop the bolus going, whichever surface sent it.
    case cancelBolus
    /// The alert screen, from the card's row.
    case showAlerts
    case nextAlert
    case clearAlert
    /// The chart's next span.
    case cycleSpan

    /// Whether the action may lead to insulin or changes the pump: those need an unlocked device. Cancel
    /// stops insulin and is never gated; leaving a screen or showing one changes nothing.
    public var needsUnlock: Bool {
        switch self {
        case .startBolus, .switchMode, .adjust, .review, .answer, .tap, .goOn, .clearAlert: true
        case .back, .close, .cancelBolus, .showAlerts, .nextAlert, .cycleSpan: false
        }
    }
}

/// One tap: the action and the screen it was drawn on.
public struct LiveActivityTap: Codable, Sendable, Hashable {
    public var screen: String
    public var action: LiveActivityAction

    public init(screen: String, action: LiveActivityAction) {
        self.screen = screen
        self.action = action
    }

    /// The tap as an intent's parameter.
    public var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public init?(encoded: String) {
        guard let tap = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)) else { return nil }
        self = tap
    }
}

/// Where the intents hand a tap to the app. The app sets `handler` at launch; the widget extension never
/// does, and iOS runs a Live Activity's intents in the app's process, not the extension's.
@MainActor
public enum LiveActivityActions {
    /// - Parameter unlocked: the tap came through the intent that needs an unlocked device.
    public static var handler: (@MainActor (LiveActivityTap, _ unlocked: Bool) async -> Void)?

    public static func run(_ encoded: String, unlocked: Bool) async {
        guard let tap = LiveActivityTap(encoded: encoded) else { return }
        await handler?(tap, unlocked)
    }
}
