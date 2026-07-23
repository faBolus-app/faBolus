#if FABOLUS_ONWATCH_EATING
import Foundation
import faBolusCore
import EatingDetectionKit
import ModelCatalogKit

// The bundled Core ML model auto-generates a class *also* named `EatingDetector` into this module,
// which would shadow the kit's type. Alias to the kit's type explicitly.
typealias Detector = EatingDetectionKit.EatingDetector

/// Apple Watch **on-device** eating detector (Phase 5, step 6). Runs `EatingDetectionKit`'s
/// `EatingDetector` locally on the watch — `MotionSensor` (CoreMotion + a minimal `HKWorkoutSession`
/// to keep sensing alive) → the bundled Core ML model → episode logic — and **relays** a p(eating)
/// to the phone (`RemoteCommand.eatingEvent`), where the fusion engine decides whether to nudge.
///
/// Entirely compiled out unless the `FABOLUS_ONWATCH_EATING` flag is set (default off): it requires
/// the **paid** HealthKit entitlement + `WKBackgroundModes: workout-processing`, so
/// `scripts/generate-project.sh` only pulls it (and this file's deps) in when the flag is on. The
/// Garmin path (phone-side inference, no HealthKit) covers everyone else. Advisory — never doses.
@MainActor
final class WatchEatingSensor: EatingDetectorDelegate {
    private var detector: Detector?
    private let onEating: (Double) -> Void

    /// `onEating` is called on the main actor with the smoothed p(eating) when an episode starts/updates.
    init(onEating: @escaping (Double) -> Void) { self.onEating = onEating }

    func start() {
        guard detector == nil else { return }
        var cfg = Detector.Config()
        if let entry = (try? ModelCatalog(bundle: .main, resource: "manifest"))?.active(for: "eating") {
            cfg.windowSamples = entry.windowSamples
            cfg.sampleRateHz = entry.sampleRateHz
            if let m = entry.mean, m.count == 6 { cfg.mean = m.map(Float.init) }
            if let s = entry.std, s.count == 6 { cfg.std = s.map(Float.init) }
            cfg.modelName = entry.id
        } else {
            // From ondevice/exported/standardization.json — used if no manifest is bundled.
            cfg.mean = [-0.20759, 0.04368, 2.15417, 0.60862, 0.68022, 0.44540]
            cfg.std  = [4.55292, 3.60938, 3.50476, 21.85199, 20.27900, 18.53563]
        }
        do {
            let d = try Detector(config: cfg)   // builds CoreMLEatingModel(named:) + MotionSensor
            d.delegate = self
            try d.start()
            detector = d
        } catch {
            detector = nil   // model unbundled or motion/HealthKit unavailable — degrade silently
        }
    }

    func stop() {
        detector?.stop()
        detector = nil
    }

    // Delegate fires off the sensor's queue — hop to the main actor to relay. Skip `.ended`
    // (the phone only nudges on likely-started/ongoing).
    nonisolated func eatingDetector(_ detector: Detector, didDetect event: Detector.EatingEvent) {
        guard event.kind != .ended else { return }
        let p = Double(event.confidence)
        Task { @MainActor in self.onEating(p) }
    }
}
#endif
