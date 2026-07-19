import AppIntents
import WidgetKit
import Foundation

/// App Intents backing the Quick-Bolus widget's 1-2-3 confirmation. Steps 1 and 2 advance (or
/// reset) the confirm progress. Completing 1→2→3 hands a pending bolus to the app via the App
/// Group and a Darwin notification; the app (running in the background with the pump connected)
/// delivers it through the validated signed path and writes status back, so the widget shows
/// progress + a cancel button in place — it never opens the app and never dispenses headlessly on
/// its own. A wrong/late tap resets. Bench/saline only.

private func postDarwin(_ name: String) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName(name as CFString), nil, nil, true)
}
private func reloadWidget() {
    WidgetCenter.shared.reloadTimelines(ofKind: "ControlX2QuickBolus")
}

/// Tap "1" or "2": advance the sequence, or reset on a wrong tap.
struct WidgetBolusStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Bolus Confirm Step"
    static let openAppWhenRun = false

    @Parameter(title: "Step") var step: Int

    init() {}
    init(step: Int) { self.step = step }

    func perform() async throws -> some IntentResult {
        let p = WidgetBolusStore.progress()
        if step == p + 1 { WidgetBolusStore.setProgress(step) } else { WidgetBolusStore.resetProgress() }
        return .result()
    }
}

/// Tap "3" (the final step): if 1→2 were completed, hand the preset bolus to the app to deliver in
/// the background (does NOT open the app). Otherwise just reset.
struct WidgetBolusDeliverIntent: AppIntent {
    static let title: LocalizedStringResource = "Deliver Widget Bolus"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        if WidgetBolusStore.progress() == 2 {
            let units = WidgetBolusStore.presetUnits
            let reqId = UUID().uuidString
            WidgetBolusStore.setPending(WidgetBolusRequest(units: units, requestId: reqId, createdAt: Date()))
            // Show "delivering" immediately; the app overwrites this with the real outcome.
            WidgetBolusStore.setStatus(WidgetBolusStatus(phase: .delivering, units: units, requestId: reqId))
            postDarwin(WidgetBolusStore.darwinPending)
        }
        WidgetBolusStore.resetProgress()
        reloadWidget()
        return .result()
    }
}

/// Cancel an in-progress widget bolus.
struct WidgetBolusCancelIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Widget Bolus"
    static let openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        postDarwin(WidgetBolusStore.darwinCancel)
        return .result()
    }
}

/// Reset the sequence (the small "×" on the widget).
struct WidgetBolusResetIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Bolus Confirm"
    static let openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        WidgetBolusStore.resetProgress(); reloadWidget(); return .result()
    }
}
