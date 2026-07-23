import Foundation
import EatingDetectionKit

// The bundled Core ML model auto-generates a class also named `EatingDetector` into the app module,
// which shadows the kit's type — reference the kit's type explicitly.
private typealias KitDetector = EatingDetectionKit.EatingDetector

/// On-device personalization for the eating nudge (Phase 5). Two layers, both fully on-device and
/// both **advisory**:
///  1. **Threshold adaptation** (`AdaptiveThresholdPersonalizer`) — always works: learns a per-user
///     bias from feedback so a user who gets false alerts gets a stricter wrist threshold over time.
///  2. **Model fine-tuning** (`OnDeviceTrainer`, `MLUpdateTask`) — when the bundled model is exported
///     *updatable*, retrains its head on the user's own labeled windows and swaps in a personalized
///     model. If the model isn't updatable (or too few examples), it degrades to layer 1 silently.
///
/// Feedback comes from the nudge: acting on it (opening the bolus screen) = a true meal; dismissing it
/// = a false alert. Off changes nothing safety-critical — it only nudges the decision threshold/model.
@MainActor
final class EatingPersonalization {
    private let personalizer: AdaptiveThresholdPersonalizer
    private let baseEnter: Double
    #if canImport(CoreML)
    // OnDeviceTrainer isn't Sendable; we own it and serialize access (add() only when not fine-tuning,
    // update() one at a time via `isFineTuning`), so its use across the update Task is safe.
    private nonisolated(unsafe) let trainer: OnDeviceTrainer
    private var isFineTuning = false
    #endif
    /// Set once a personalized model has been written; `EatingAccelPipeline` prefers it.
    private(set) var personalizedModelURL: URL?
    /// Called after a successful fine-tune so the app can reload inference with the new model.
    var onModelUpdated: (() -> Void)?

    init(windowSamples: Int = 150) {
        var cfg = KitDetector.Config()
        cfg.windowSamples = windowSamples
        baseEnter = Double(cfg.enterThreshold)
        personalizer = AdaptiveThresholdPersonalizer(base: cfg)
        #if canImport(CoreML)
        trainer = OnDeviceTrainer(windowSamples: windowSamples)
        // Reuse a personalized model from a previous run if present.
        if FileManager.default.fileExists(atPath: trainer.personalizedModelURL.path) {
            personalizedModelURL = trainer.personalizedModelURL
        }
        #endif
    }

    /// Learned add-on to the user's wrist threshold (≥ 0). Grows when the user reports false alerts.
    var thresholdBias: Double { max(0, Double(personalizer.enterThreshold) - baseEnter) }
    var confirmedTrue: Int { stats.tp }
    var confirmedFalse: Int { stats.fp }
    private var stats: (bias: Float, fp: Int, tp: Int) { UserDefaultsStore().load() }

    /// Record what the user did after a nudge. `window` (raw interleaved IMU) is optional — only the
    /// wrist path has one; the CGM-only path still adapts the threshold.
    func recordFeedback(eating: Bool, window: [Float]?) {
        personalizer.record(eating ? .confirmedEating : .notEating)
        #if canImport(CoreML)
        if let window, window.count > 0, !isFineTuning { trainer.add(window: window, eating: eating) }
        maybeFineTune()
        #endif
    }

    func reset() {
        personalizer.reset()
        personalizedModelURL = nil
    }

    #if canImport(CoreML)
    private func maybeFineTune() {
        guard !isFineTuning, trainer.shouldUpdate,
              let base = Bundle.main.url(forResource: "EatingDetector", withExtension: "mlmodelc") else { return }
        isFineTuning = true
        let box = TrainerBox(trainer)   // @unchecked Sendable; serialized by isFineTuning
        Task { [weak self] in
            defer { Task { @MainActor in self?.isFineTuning = false } }
            do {
                try await box.trainer.update(baseModelURL: base)   // throws if the model isn't updatable
                await MainActor.run {
                    self?.personalizedModelURL = box.trainer.personalizedModelURL
                    self?.onModelUpdated?()
                }
            } catch {
                // Not updatable / update failed — the threshold layer already adapted; nothing else to do.
            }
        }
    }
    #endif
}

#if canImport(CoreML)
/// Ships the non-Sendable trainer into the update Task. Safe: only one update runs at a time
/// (`isFineTuning`) and `add()` is skipped while one is in flight.
private struct TrainerBox: @unchecked Sendable {
    let trainer: OnDeviceTrainer
    init(_ t: OnDeviceTrainer) { trainer = t }
}
#endif
