import AppIntents
import Foundation

/// App Intents backing the Quick-Bolus widget's 1-2-3 confirmation. Steps 1 and 2 just advance
/// (or reset) the confirm progress in the App Group without opening the app. The final "3" opens
/// the app and, only if 1→2 were tapped in order, writes a pending bolus the app delivers through
/// the validated signed path. A wrong or late tap resets — a stray tap can never dispense.

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

/// Tap "3" (the final step): opens the app. If 1→2 were completed, hands the preset bolus to the
/// app to deliver; otherwise it just resets (the app opens but nothing is delivered).
struct WidgetBolusDeliverIntent: AppIntent {
    static let title: LocalizedStringResource = "Deliver Widget Bolus"
    static let openAppWhenRun = true   // deliver + show progress/cancel in the app, never headless

    func perform() async throws -> some IntentResult {
        if WidgetBolusStore.progress() == 2 {
            WidgetBolusStore.setPending(WidgetBolusRequest(units: WidgetBolusStore.presetUnits,
                                                           requestId: UUID().uuidString,
                                                           createdAt: Date()))
        }
        WidgetBolusStore.resetProgress()
        return .result()
    }
}

/// Reset the sequence (the small "×" on the widget).
struct WidgetBolusResetIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Bolus Confirm"
    static let openAppWhenRun = false
    func perform() async throws -> some IntentResult { WidgetBolusStore.resetProgress(); return .result() }
}
