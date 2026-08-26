import Foundation
import faBolusCore
#if FABOLUS_NUDGE
import GlucoseIntelligenceKit
import AlertIntelligenceKit
#endif

/// Phase 16 GO-1 Step 4 (16-04, REMED-16, R2) — the eating-nudge (multi-signal fusion) METHODS moved
/// verbatim out of `AppModel.swift` into this separate-file extension. Behavior-preserving: every
/// function body below is an unchanged copy of the original `AppModel` member, with the same `#if
/// FABOLUS_NUDGE` gates preserved exactly.
///
/// **Review concern #1 (NOT verbatim/zero-interface-change):** a Swift extension in a SEPARATE file
/// cannot declare stored properties and cannot see a `private` member of the type it extends, so
/// every stored property these methods touch (`eatingEngine`, `lastEatingConfig`, `lastAccelWindowAt`,
/// `lastAccelWindowRaw`, `eatingLocation`, `lastWantAccel`, `lastEatingPositiveAt`, `eatingNudge`,
/// `alertIntel`, `history`, and the `#if FABOLUS_NUDGE`-gated `mealDetector`/`accelPipeline`/
/// `eatingPersonalization`) stays declared in `AppModel.swift`'s main body, widened `private`->
/// `internal` there (never beyond `internal`). See `AppModel.swift`'s own comments at each widened
/// declaration and `AppModelAccessWideningGuardTests` (16-04 Task 3), which pins the widened set as
/// EXACTLY this enumerated list — no dose/gate member included.
///
/// `updateEatingNudge()` and `maybeAutoImportAppleHealth`-style throttled wrappers elsewhere still
/// need to be called from `AppModel.refresh()`/`init` in the main file — those two call sites (plus
/// `setupEatingPersonalization()`'s init-time call) are why `updateEatingNudge()` below is `internal`
/// (was `private`) rather than staying private; `setupEatingPersonalization()` was already `internal`
/// (no modifier) before this carve.
extension AppModel {

    /// De-duped setter: only fire the accel-sensing control signal on an actual change (mirrors
    /// `setWantHeartRate`, which stays in `AppModel.swift` — HR is a separate, unmoved feature).
    private func setWantAccelSensing(_ on: Bool) {
        guard on != lastWantAccel else { return }
        lastWantAccel = on
        onWantAccelSensing?(on)
    }

    /// Feed a raw IMU window from the Garmin watch (imu_window message) → phone-side p(eating).
    public func ingestGarminIMUWindow(rawWindow raw: [Float]) {
        #if FABOLUS_NUDGE
        guard let p = accelPipeline.predict(rawWindow: raw) else { return }
        latestAccelProb = p
        lastAccelWindowAt = Date()
        lastAccelWindowRaw = raw            // retained on-device to label if the user gives feedback
        #endif
    }

    /// Hook up on-device personalization: reload inference with the user's fine-tuned model when one is
    /// produced, and prefer any personalized model from a previous run. Call once after init.
    func setupEatingPersonalization() {
        #if FABOLUS_NUDGE
        eatingPersonalization.onModelUpdated = { [weak self] in
            guard let self else { return }
            if AppSettings.shared.eatingLearnFromFeedback {
                self.accelPipeline.applyPersonalizedModel(self.eatingPersonalization.personalizedModelURL)
            }
        }
        if AppSettings.shared.eatingLearnFromFeedback {
            accelPipeline.applyPersonalizedModel(eatingPersonalization.personalizedModelURL)
        }
        #endif
    }

    /// The user acted on the eating nudge (opened the bolus screen) → treat as a confirmed meal: teach
    /// the personalizer + learn this as a meal place. Advisory-only feedback.
    public func eatingNudgeActedOn() {
        #if FABOLUS_NUDGE
        if AppSettings.shared.eatingLearnFromFeedback {
            eatingPersonalization.recordFeedback(eating: true, window: lastAccelWindowRaw)
        }
        #endif
        lastEatingPositiveAt = Date()   // de-dupe against the silent pre-bolus positive path
        eatingLocation.recordMealHere()
        eatingNudge = nil
    }

    /// Apple Watch on-device path: the watch already ran the model and relays a p(eating). Feed it
    /// straight into the same accel signal the Garmin window path produces, then re-fuse the nudge.
    public func ingestWatchEatingEvent(prob: Double, at: Date = Date()) {
        latestAccelProb = prob
        lastAccelWindowAt = at
        updateEatingNudge()
    }

    /// Persist the learned alarm-fatigue decision for advisory alerts to `UserDefaults`. Moved with
    /// its only caller, `dismissEatingNudge()`; `loadAlertIntel()` (the paired loader) stays in
    /// `AppModel.swift` — it is only ever referenced from `alertIntel`'s own default-value expression,
    /// in that same file.
    #if FABOLUS_NUDGE
    private func saveAlertIntel() {
        if let d = try? JSONEncoder().encode(alertIntel) { UserDefaults.standard.set(d, forKey: "alertIntel") }
    }
    #endif

    /// Multi-signal eating nudge: gather CGM-meal + accel + no-recent-bolus, run the trigger engine, and
    /// (if it fires and the fatigue layer allows) surface an advisory nudge. Advisory only, never doses.
    /// `internal` (was `private` in `AppModel.swift`) — still called from `AppModel.refresh()` there.
    func updateEatingNudge() {
        #if !FABOLUS_NUDGE
        eatingNudge = nil; return   // Smart Assist (eating detection) needs the faBolusNudge SDK
        #else
        guard AppSettings.shared.eatingNudgesEnabled else {
            eatingNudge = nil; setWantAccelSensing(false); eatingLocation.setEnabled(false); return
        }
        var cfg = AppSettings.shared.eatingTriggerConfig
        // On-device threshold adaptation: raise the wrist threshold by the learned bias (fewer false
        // alerts for users who report them). Off = no change.
        if AppSettings.shared.eatingLearnFromFeedback {
            cfg.accelThreshold = min(0.98, cfg.accelThreshold + eatingPersonalization.thresholdBias)
        }
        eatingLocation.setEnabled(cfg.locationEnabled)
        if let d = try? JSONEncoder().encode(cfg), d != lastEatingConfig { eatingEngine.setConfig(cfg); lastEatingConfig = d }
        guard let history else { return }

        let range = Date().addingTimeInterval(-2 * 3600)...Date()
        var meal: MealDetector.Result?
        if cfg.mode.usesCGM, snapshot.isf > 0, snapshot.carbRatio > 0 {
            meal = mealDetector.detect(
                glucose: history.glucose(in: range).map { (date: $0.date, mgdl: Double($0.mgdl)) },
                doses: history.boluses(in: range).map { (date: $0.date, units: $0.units) },
                announcedCarbs: history.carbs(in: range),
                carbRatio: snapshot.carbRatio, isf: Double(snapshot.isf))
        }
        // Battery: for cgmThenAccel, only spin up the wrist sensor once the CGM hints a possible meal;
        // other accel modes keep it on while enabled.
        let wantAccel = cfg.mode.usesAccel && (cfg.mode == .cgmThenAccel ? (meal?.score ?? 0) >= 0.3 : true)
        setWantAccelSensing(wantAccel)

        let minsSinceBolus = bolusMarkers.map(\.date).max()
            .map { Date().timeIntervalSince($0) / 60 } ?? .greatestFiniteMagnitude
        // Accel is only valid while the wrist is actively streaming (stale windows → treat as unavailable).
        let accelFresh = Date().timeIntervalSince(lastAccelWindowAt) < 120 ? latestAccelProb : nil
        let signals = EatingSignals(accelProb: cfg.mode.usesAccel ? accelFresh : nil,
                                    cgmMealScore: meal?.score, minutesSinceBolus: minsSinceBolus,
                                    atMealPlace: cfg.locationEnabled ? eatingLocation.isAtMealPlace() : nil)

        // Silent positive training example: eating is *recognized* but the nudge is gated by a recent
        // bolus → you pre-bolused. No prompt (you already dosed), but label it a true meal for the
        // on-device personalizer/trainer. Debounced to ~one per meal; window passed only when fresh.
        if AppSettings.shared.eatingLearnFromFeedback,
           eatingEngine.signalsMet(signals),
           minsSinceBolus < Double(cfg.minMinutesSinceBolus),
           Date().timeIntervalSince(lastEatingPositiveAt) > 90 * 60 {
            lastEatingPositiveAt = Date()
            eatingPersonalization.recordFeedback(eating: true, window: accelFresh != nil ? lastAccelWindowRaw : nil)
            eatingLocation.recordMealHere()
        }

        if case .fire = eatingEngine.evaluate(signals) {
            if case .suppress = alertIntel.decide(AlertIntelligenceKit.Alert(kind: "eating", severity: 1)) { return }
            eatingNudge = EatingAlert(estimatedCarbs: meal?.estimatedCarbs ?? 0, at: Date())
        }
        #endif
    }

    /// User dismissed the eating nudge → teach the eating fatigue layer + the on-device personalizer
    /// (a false alert), then clear it.
    public func dismissEatingNudge() {
        #if FABOLUS_NUDGE
        alertIntel.record("eating", .dismissed); saveAlertIntel()
        if AppSettings.shared.eatingLearnFromFeedback {
            eatingPersonalization.recordFeedback(eating: false, window: lastAccelWindowRaw)
        }
        #endif
        eatingNudge = nil
    }

    /// Learned meal-place count + personalization stats (for the settings screen).
    public var eatingLearnedPlaceCount: Int { eatingLocation.learnedPlaceCount }
    public var eatingFeedbackStats: (confirmed: Int, falseAlerts: Int) {
        #if FABOLUS_NUDGE
        (eatingPersonalization.confirmedTrue, eatingPersonalization.confirmedFalse)
        #else
        (0, 0)
        #endif
    }
    public func resetEatingPersonalization() {
        #if FABOLUS_NUDGE
        eatingPersonalization.reset()
        accelPipeline.applyPersonalizedModel(nil)
        #endif
        eatingLocation.reset()
    }
}
