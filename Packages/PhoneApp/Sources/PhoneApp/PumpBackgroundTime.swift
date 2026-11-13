#if canImport(UIKit)
import TandemBLE
import UIKit

/// Background time for the pump link (`beginBackgroundTask`): a reconnect cooldown that starts in the
/// background is waited out instead of the app being suspended with no pending connect. iOS gives about
/// 30 s, the longest cooldown; if it ends sooner the link connects at once.
@MainActor
final class PumpBackgroundTime: LinkBackgroundTime {
    func begin(ending: @escaping @MainActor () -> Void) -> (any LinkClockToken)? {
        let hold = Hold()
        // Held strongly: the link lets go of its token inside `ending`, and an expired task that isn't
        // ended gets the app terminated.
        hold.id = UIApplication.shared.beginBackgroundTask(withName: "pump reconnect cooldown") {
            ending()
            hold.cancel()
        }
        return hold.id == .invalid ? nil : hold
    }

    final class Hold: LinkClockToken {
        var id: UIBackgroundTaskIdentifier = .invalid

        func cancel() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
#endif
