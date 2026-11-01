import Foundation

/// The "Pump disconnected" schedule (pure).
///
/// When the pump stops being reachable, the app schedules the first notice at the delay the user chose
/// (`AlertPolicy.PumpDisconnectDelay`) and two follow-ups at 15 and 30 minutes after the drop, with
/// stronger copy that tells the user to use the pump's own buttons. Each is an OS-scheduled notification,
/// so it fires while the app is suspended, and all of them are withdrawn when the pump reconnects. A
/// follow-up at or before the first notice is left out, so the first notice is never preceded or
/// duplicated by one. The ladder is finite on purpose: a notification that nagged forever would train
/// the user to ignore it.
///
/// Notification-only: nothing here blocks, delays or affects a dose or a pump command.
public enum DisconnectEscalation {

    /// One scheduled notice: fire `afterSeconds` past the drop, with this copy. `id` is the notification
    /// identifier, distinct per step so no step replaces another.
    public struct Step: Equatable, Sendable {
        public let id: String
        public let afterSeconds: TimeInterval
        public let title: String
        /// Every step tells the user to use the pump's own buttons, the one thing they can do while the
        /// app can't reach the pump.
        public let body: String
        public init(id: String, afterSeconds: TimeInterval, title: String, body: String) {
            self.id = id
            self.afterSeconds = afterSeconds
            self.title = title
            self.body = body
        }
    }

    /// The instruction every notice carries.
    public static let pumpButtonsInstruction =
        "Use the pump's own buttons to bolus or check status until it reconnects."

    /// The first notice's identifier.
    public static let firstNoticeId = "safety.pumpDisconnect"

    /// The first notice, at the user's delay.
    public static func firstNotice(afterSeconds: TimeInterval) -> Step {
        Step(
            id: firstNoticeId, afterSeconds: afterSeconds, title: "Pump disconnected",
            body: "faBolus lost the connection to your pump. \(pumpButtonsInstruction)")
    }

    /// The follow-ups, by ascending `afterSeconds`. Timings are the old app's (owner-vetoable starting
    /// points, not clinical constants).
    public static let steps: [Step] = [
        Step(
            id: "safety.pumpDisconnect.escalation.15m",
            afterSeconds: 15 * 60,
            title: "Pump still disconnected",
            body: "faBolus still can't reach your pump (15 min). \(pumpButtonsInstruction)"),
        Step(
            id: "safety.pumpDisconnect.escalation.30m",
            afterSeconds: 30 * 60,
            title: "Pump disconnected — act on the pump",
            body: "faBolus has been unable to reach your pump for 30 minutes. \(pumpButtonsInstruction)")
    ]

    /// Every identifier the schedule can use, for withdrawal on reconnect.
    public static var allIds: [String] { [firstNoticeId] + steps.map(\.id) }

    /// The notices for a drop with the user's delay: the first notice, then each follow-up that comes
    /// after it. Empty for `never`.
    public static func schedule(delay: AlertPolicy.PumpDisconnectDelay) -> [Step] {
        guard let first = delay.seconds else { return [] }
        return [firstNotice(afterSeconds: first)] + steps.filter { $0.afterSeconds > first }
    }
}
