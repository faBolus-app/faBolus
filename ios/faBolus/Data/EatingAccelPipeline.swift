import Foundation
import EatingDetectionKit
import ModelCatalogKit

/// Phone-side eating inference on raw IMU windows streamed from the Garmin watch. Standardizes each raw
/// window with the model's training stats (from the ModelCatalogKit manifest, or the shipped fallback),
/// then runs the Core ML model → p(eating). **Graceful:** if the model isn't bundled, `predict` returns
/// nil and the accel signal is simply unavailable (CGM-only modes still work). See MIGRATION.md / plan.
final class EatingAccelPipeline {
    private let model: EatingModel?
    private let mean: [Float]
    private let std: [Float]
    private let windowSamples: Int

    init() {
        let entry = (try? ModelCatalog(bundle: .main, resource: "manifest"))?.active(for: "eating")
        windowSamples = entry?.windowSamples ?? 150
        mean = entry?.mean.map { $0.map(Float.init) } ?? Self.fallbackMean
        std = entry?.std.map { $0.map(Float.init) } ?? Self.fallbackStd
        model = try? CoreMLEatingModel(named: entry?.id ?? "EatingDetector", windowSamples: windowSamples)
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
