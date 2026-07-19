import Foundation
import Observation

/// Observable app state bridging a `PumpDataSource` to SwiftUI.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public var lastError: String?

    private let source: PumpDataSource

    public init(source: PumpDataSource) {
        self.source = source
        self.snapshot = source.snapshot
        self.glucoseHistory = source.glucoseHistory
        source.onChange = { [weak self] in self?.refresh() }
    }

    private func refresh() {
        snapshot = source.snapshot
        glucoseHistory = source.glucoseHistory
    }

    public func connect() async { await source.connect(); refresh() }
    public func disconnect() { source.disconnect(); refresh() }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        await source.recommendBolus(carbsGrams: carbsGrams, bgMgdl: bgMgdl)
    }

    public func deliverBolus(units: Double) async {
        do { _ = try await source.deliverBolus(units: units); lastError = nil }
        catch { lastError = error.localizedDescription }
        refresh()
    }

    public func cancelBolus() async { await source.cancelBolus(); refresh() }
}
