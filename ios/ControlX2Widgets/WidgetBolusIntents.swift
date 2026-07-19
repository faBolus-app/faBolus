import AppIntents
import WidgetKit
import Foundation

/// App Intents backing the Quick-Bolus widget. The flow mirrors the Garmin remote: choose an
/// amount (− / +), tap **Bolus**, then confirm with a **1-2-3** sequential tap. Completing the
/// sequence hands the dose to the app via the App Group + a Darwin notification; the app (running
/// in the background with the pump connected) delivers it through the validated signed path and
/// writes status back, so the widget shows progress + cancel in place. It never opens the app and
/// never dispenses on a stray tap (a wrong/late 1-2-3 tap resets). Bench/saline only.

private func postDarwin(_ name: String) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName(name as CFString), nil, nil, true)
}
private func reloadWidget() {
    WidgetCenter.shared.reloadTimelines(ofKind: "ControlX2QuickBolus")
}

/// − / + the dose on the amount stage (step = the configured bolus increment).
struct WidgetBolusAdjustIntent: AppIntent {
    static let title: LocalizedStringResource = "Adjust Bolus Amount"
    static let openAppWhenRun = false

    @Parameter(title: "Delta") var delta: Int   // +1 or -1

    init() {}
    init(delta: Int) { self.delta = delta }

    func perform() async throws -> some IntentResult {
        let step = WidgetBolusStore.increment
        var v = WidgetBolusStore.draft + Double(delta) * step
        // Snap to the increment grid and clamp to [0, max].
        v = (v / step).rounded() * step
        WidgetBolusStore.draft = min(max(0, v), WidgetBolusStore.maxBolus)
        reloadWidget()
        return .result()
    }
}

/// "Bolus" on the amount stage → advance to the 1-2-3 confirm (only if a dose is set).
struct WidgetBolusBeginConfirmIntent: AppIntent {
    static let title: LocalizedStringResource = "Confirm Bolus Amount"
    static let openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        if WidgetBolusStore.draft > 0 { WidgetBolusStore.stage = "confirm"; WidgetBolusStore.resetProgress() }
        reloadWidget()
        return .result()
    }
}

/// "Back" on the confirm stage → return to the amount stage (keep the dose).
struct WidgetBolusBackIntent: AppIntent {
    static let title: LocalizedStringResource = "Back to Amount"
    static let openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        WidgetBolusStore.stage = "amount"; WidgetBolusStore.resetProgress(); reloadWidget()
        return .result()
    }
}

/// Tap "1" or "2" on the confirm stage: advance the sequence, or reset on a wrong tap.
struct WidgetBolusStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Bolus Confirm Step"
    static let openAppWhenRun = false

    @Parameter(title: "Step") var step: Int

    init() {}
    init(step: Int) { self.step = step }

    func perform() async throws -> some IntentResult {
        let p = WidgetBolusStore.progress()
        if step == p + 1 { WidgetBolusStore.setProgress(step) } else { WidgetBolusStore.resetProgress() }
        reloadWidget()
        return .result()
    }
}

/// Tap "3" (the final step): if 1→2 were completed and a dose is set, deliver in the background.
struct WidgetBolusDeliverIntent: AppIntent {
    static let title: LocalizedStringResource = "Deliver Widget Bolus"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let units = WidgetBolusStore.draft
        if WidgetBolusStore.stage == "confirm", WidgetBolusStore.progress() == 2, units > 0 {
            let reqId = UUID().uuidString
            WidgetBolusStore.setPending(WidgetBolusRequest(units: units, requestId: reqId, createdAt: Date()))
            WidgetBolusStore.setStatus(WidgetBolusStatus(phase: .delivering, units: units, requestId: reqId))
            postDarwin(WidgetBolusStore.darwinPending)
        }
        WidgetBolusStore.resetEntry()
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
