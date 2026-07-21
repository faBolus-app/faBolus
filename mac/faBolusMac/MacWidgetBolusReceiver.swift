import Foundation
import faBolusCore

extension Notification.Name {
    static let macWidgetBolusPending = Notification.Name("fabolus.mac.widgetBolusPending")
    static let macWidgetBolusCancel = Notification.Name("fabolus.mac.widgetBolusCancel")
}

/// Relays a bolus the Mac quick-bolus widget confirmed (1-2-3) to the phone over the link. The
/// widget posts a Darwin notification (same names as the iOS widget); this receiver — alive while
/// the Mac app runs — reads the pending request and hands it to `MacRemoteModel`, which sends it to
/// the phone and mirrors the phone's echoes back into the widget's status. Structurally the same as
/// the iOS `WidgetBolusReceiver`, except delivery is a relayed command rather than a local pump call.
@MainActor
final class MacWidgetBolusReceiver {
    private weak var model: MacRemoteModel?

    init(model: MacRemoteModel) {
        self.model = model
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
            NotificationCenter.default.post(name: .macWidgetBolusPending, object: nil)
        }, WidgetBolusStore.darwinPending as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
            NotificationCenter.default.post(name: .macWidgetBolusCancel, object: nil)
        }, WidgetBolusStore.darwinCancel as CFString, nil, .deliverImmediately)

        NotificationCenter.default.addObserver(forName: .macWidgetBolusPending, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.deliverWidgetPending() }
        }
        NotificationCenter.default.addObserver(forName: .macWidgetBolusCancel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.cancel() }
        }
    }
}
