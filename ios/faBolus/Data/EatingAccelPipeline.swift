#if FABOLUS_NUDGE
import Foundation
import EatingDetectionKit
import ModelCatalogKit

/// Phone-side eating inference on raw IMU windows streamed from the Garmin watch. Standardizes each raw
/// window with the model's training stats (from the ModelCatalogKit manifest, or the shipped fallback),
/// then runs the Core ML model → p(eating). **Graceful:** if the model isn't bundled, `predict` returns
/// nil and the accel signal is simply unavailable (CGM-only modes still work). See MIGRATION.md / plan.
final class EatingAccelPipeline {
    private var model: EatingModel?
    private let bundledModel: EatingModel?
    private let mean: [Float]
    private let std: [Float]
    private let windowSamples: Int

    init() {
        let entry = (try? ModelCatalog(bundle: .main, resource: "manifest"))?.active(for: "eating")
        windowSamples = entry?.windowSamples ?? 150
        mean = entry?.mean.map { $0.map(Float.init) } ?? Self.fallbackMean
        std = entry?.std.map { $0.map(Float.init) } ?? Self.fallbackStd
        bundledModel = try? CoreMLEatingModel(named: entry?.id ?? "EatingDetector", windowSamples: windowSamples)
        model = bundledModel
    }

    /// Prefer the user's on-device fine-tuned model when one exists; fall back to the bundled model.
    /// See `EatingPersonalization`. No-op if the personalized model can't be loaded.
    func applyPersonalizedModel(_ url: URL?) {
        #if canImport(CoreML)
        if let url, let m = try? URLEatingModel(url: url, windowSamples: windowSamples) {
            model = m
        } else {
            model = bundledModel
        }
        #endif
    }

    var isAvailable: Bool { model != nil }

    /// Raw interleaved window `[ax,ay,az,gx,gy,gz, …]` (length `windowSamples*6`) → p(eating), or nil.
    func predict(rawWindow: [Float]) -> Double? {
        guard let model, rawWindow.count == windowSamples * 6, mean.count == 6, std.count == 6 else { return nil }
        var standardized = [Float](); standardized.reserveCapacity(rawWindow.count)
        for t in 0..<windowSamples {
            for c in 0..<6 { standardized.append((rawWindow[t * 6 + c] - mean[c]) / std[c]) }
        }
        return Double(model.predict(standardized))
    }

    // From ondevice/exported/standardization.json — used only if no manifest is bundled.
    static let fallbackMean: [Float] = [-0.20759, 0.04368, 2.15417, 0.60862, 0.68022, 0.44540]
    static let fallbackStd: [Float]  = [4.55292, 3.60938, 3.50476, 21.85199, 20.27900, 18.53563]
}

#if canImport(CoreML)
import CoreML

/// Loads an on-device fine-tuned Core ML model from a **file URL** (Application Support), mirroring
/// `CoreMLEatingModel`'s I/O (input "window" [1,6,W]; output "eating_prob"). The SDK loader only reads
/// from a bundle by name, so this covers the personalized-model path. See `EatingPersonalization`.
private struct URLEatingModel: EatingModel {
    private let model: MLModel
    private let windowSamples: Int
    init(url: URL, windowSamples: Int) throws {
        self.model = try MLModel(contentsOf: url)
        self.windowSamples = windowSamples
    }
    func predict(_ window: [Float]) -> Float {
        guard let arr = try? MLMultiArray(shape: [1, 6, NSNumber(value: windowSamples)], dataType: .float32) else { return 0 }
        for t in 0..<windowSamples { for c in 0..<6 { arr[[0, c, t] as [NSNumber]] = NSNumber(value: window[t * 6 + c]) } }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(
                dictionary: ["window": MLFeatureValue(multiArray: arr)])) else { return 0 }
        if let v = out.featureValue(for: "eating_prob")?.multiArrayValue { return Float(truncating: v[v.count - 1]) }
        return Float(out.featureValue(for: "eating_prob")?.doubleValue ?? 0)
    }
}
#endif
#endif // FABOLUS_NUDGE
