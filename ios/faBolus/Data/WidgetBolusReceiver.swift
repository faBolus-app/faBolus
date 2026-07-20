import Foundation
import WidgetKit

extension Notification.Name {
    static let widgetBolusPending = Notification.Name("fabolus.widgetBolusPending")
    static let widgetBolusCancel = Notification.Name("fabolus.widgetBolusCancel")
}

/// Delivers a bolus the Quick-Bolus widget confirmed (1-2-3) without opening the app. The widget
/// posts a Darwin notification; this receiver (alive whenever the app is running — including in the
/// background with the pump connected via `bluetooth-central`) picks up the pending request, drives
/// delivery through the validated signed path, and writes status back to the App Group so the
/// widget shows progress + a cancel button in place.
@MainActor
final class WidgetBolusReceiver {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        // The C callbacks capture nothing; they re-post as Foundation notifications handled below.
        CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
            NotificationCenter.default.post(name: .widgetBolusPending, object: nil)
        }, WidgetBolusStore.darwinPending as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
            NotificationCenter.default.post(name: .widgetBolusCancel, object: nil)
        }, WidgetBolusStore.darwinCancel as CFString, nil, .deliverImmediately)

        NotificationCenter.default.addObserver(forName: .widgetBolusPending, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePending() }
        }
        NotificationCenter.default.addObserver(forName: .widgetBolusCancel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                Task { await model.cancelBolus() }
            }
        }
    }

    private func reload() { WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus") }

    /// Consume a pending widget bolus and deliver it, updating the widget's status as it goes.
    /// Called on the Darwin wake and again when the app becomes active (a suspended-app fallback).
    func handlePending() {
        guard let model, let r = WidgetBolusStore.takePending() else { return }
        Task {
            // Carbs → units via the pump's calculator (same as the Garmin remote); units go as-is.
            let units: Double
            if r.mode == "carbs" {
                let rec = await model.recommendBolus(carbsGrams: r.amount, bgMgdl: model.snapshot.glucose)
                units = rec.recommendedUnits
            } else {
                units = r.amount
            }
            guard units > 0 else {
                WidgetBolusStore.setStatus(WidgetBolusStatus(phase: .failed, requestId: r.requestId,
                                                             message: "No insulin needed"))
                reload(); return
            }
            WidgetBolusStore.setStatus(WidgetBolusStatus(phase: .delivering, units: units, requestId: r.requestId))
            reload()
            let out = await model.deliverWidgetBolus(requestId: r.requestId, units: units)
            let phase: WidgetBolusPhase = out.error != nil ? .failed : (out.cancelled ? .cancelled : .delivered)
            WidgetBolusStore.setStatus(WidgetBolusStatus(phase: phase, units: units,
                                                         deliveredUnits: out.delivered, requestId: r.requestId,
                                                         message: out.error ?? ""))
            reload()
        }
    }
}
