import AppIntents
import WidgetKit
import Foundation

/// App Intents backing the Quick-Bolus widget. The flow mirrors the Garmin remote: choose an
/// amount (− / +), tap **Bolus**, then confirm with a **1-2-3** sequential tap. Completing the
/// sequence hands the dose to the app via the App Group + a Darwin notification; the app (running
/// in the background with the pump connected) delivers it through the validated signed path and
/// writes status back, so the widget shows progress + cancel in place. It never opens the app and
/// never dispenses on a stray tap (a wrong/late 1-2-3 tap resets).

private func postDarwin(_ name: String) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName(name as CFString), nil, nil, true)
}
private func reloadWidget() {
    WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus")
}

/// − / + the amount on the amount stage. Step + max depend on the mode (units vs carbs).
struct WidgetBolusAdjustIntent: AppIntent {
    static let title: LocalizedStringResource = "Adjust Bolus Amount"
    static let openAppWhenRun = false

    @Parameter(title: "Delta") var delta: Int   // +1 or -1

    init() {}
    init(delta: Int) { self.delta = delta }

    func perform() async throws -> some IntentResult {
        let carbs = WidgetBolusStore.mode == "carbs"
        let step = carbs ? WidgetBolusStore.carbIncrement : WidgetBolusStore.increment
        let maxV = carbs ? WidgetBolusStore.maxCarbs : WidgetBolusStore.maxBolus
        var v = WidgetBolusStore.draft + Double(delta) * step
        v = (v / step).rounded() * step   // snap to the increment grid
        WidgetBolusStore.draft = min(max(0, v), maxV)
        reloadWidget()
        return .result()
    }
}

/// Tap the units/carbs label to switch modes (resets the amount, like the Garmin mode chip).
struct WidgetBolusToggleModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Units/Carbs"
    static let openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        WidgetBolusStore.mode = (WidgetBolusStore.mode == "carbs") ? "units" : "carbs"
        WidgetBolusStore.draft = 0
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
        let amount = WidgetBolusStore.draft
        if WidgetBolusStore.stage == "confirm", WidgetBolusStore.progress() == 2, amount > 0 {
            let reqId = UUID().uuidString
            let mode = WidgetBolusStore.mode
            WidgetBolusStore.setPending(WidgetBolusRequest(amount: amount, mode: mode, requestId: reqId, createdAt: Date()))
            // `units` here is the entered amount for display; the app writes the real delivered units.
            WidgetBolusStore.setStatus(WidgetBolusStatus(phase: .delivering, units: mode == "units" ? amount : 0, requestId: reqId))
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
