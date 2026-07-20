import Foundation
import faBolusCore

/// In-memory pump simulator so the HUD runs in the Simulator / SwiftUI previews with no
/// hardware. Generates a plausible glucose trace and simple IOB/COB dynamics. A reference
/// `PumpBackend` implementation — copy it as a starting point for a new backend.
@MainActor
public final class MockBackend: PumpBackend {
    public let capabilities: PumpCapabilities = .full
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = [
        PumpAlert(id: 0, kind: .alert, title: "Low insulin",
                  detail: "Low amount of insulin remaining in the cartridge.")
    ]
    public var alertDebug: String { "mock" }
    public private(set) var lastBolusCancelled = false
    public func dismissNotification(_ alert: PumpAlert) async {
        activeNotifications.removeAll { $0.id == alert.id && $0.kind == alert.kind }
        onChange?()
    }
    public var pairingCode: String = ""   // unused by the mock
    public var hasStoredPairing: Bool { false }
    public func forgetPairing() {}
    public var onChange: (@MainActor () -> Void)?

    private var timer: Timer?

    public init() { seedHistory() }

    private func seedHistory() {
        let now = Date()
        var value = 120.0
        var readings: [GlucoseReading] = []
        // 3 hours of 5-minute CGM samples, gently oscillating.
        for i in stride(from: 36, through: 0, by: -1) {
            let t = now.addingTimeInterval(TimeInterval(-i * 300))
            value += Double.random(in: -8...8)
            value = min(max(value, 70), 220)
            readings.append(GlucoseReading(date: t, mgdl: Int(value)))
        }
        glucoseHistory = readings
        // Sample IOB decay + a couple of boluses for the chart overlay.
        iobHistory = stride(from: 36, through: 0, by: -1).map {
            IOBSample(date: now.addingTimeInterval(TimeInterval(-$0 * 300)),
                      iob: max(0, 3.0 - Double(36 - $0) * 0.07))
        }
        bolusMarkers = [
            BolusMarker(date: now.addingTimeInterval(-3600), units: 2.0),
            BolusMarker(date: now.addingTimeInterval(-1500), units: 1.0),
        ]
        snapshot.glucose = readings.last?.mgdl
        snapshot.iobUnits = 1.4
        snapshot.reservoirUnits = 142
        snapshot.batteryPercent = 78
        snapshot.cgmActive = true
        snapshot.carbRatio = 10; snapshot.isf = 40; snapshot.targetBg = 110; snapshot.maxBolusUnits = 25
        snapshot.lastBolusUnits = 2.0
        snapshot.lastBolusDate = now.addingTimeInterval(-3600)
    }

    public func connect() async {
        snapshot.connection = .scanning; onChange?()
        try? await Task.sleep(nanoseconds: 500_000_000)
        snapshot.connection = .connecting; onChange?()
        try? await Task.sleep(nanoseconds: 500_000_000)
        snapshot.connection = .connected; onChange?()
        startTicking()
    }

    public func disconnect() {
        timer?.invalidate(); timer = nil
        snapshot.connection = .disconnected; onChange?()
    }

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard var last = glucoseHistory.last?.mgdl else { return }
        last = min(max(last + Int.random(in: -6...6), 60), 240)
        glucoseHistory.append(GlucoseReading(date: Date(), mgdl: last))
        if glucoseHistory.count > 72 { glucoseHistory.removeFirst() }
        snapshot.glucose = last
        snapshot.iobUnits = max(0, snapshot.iobUnits - 0.02)
        onChange?()
    }

    /// Simple mock calculator: carbs/10 (carb ratio) + correction toward 110 / 40 (ISF),
    /// minus IOB. Real source uses the pump's bolus calculator.
    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams
        rec.bgMgdl = bgMgdl
        rec.iobUnits = snapshot.iobUnits
        let carbUnits = carbsGrams / 10.0
        let correction = bgMgdl.map { max(0, Double($0 - 110) / 40.0) } ?? 0
        rec.recommendedUnits = max(0, (carbUnits + correction - snapshot.iobUnits))
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20   // round to 0.05u
        return rec
    }

    public func deliverBolus(units: Double) async throws -> Double {
        guard snapshot.connection == .connected else { throw BolusError.notConnected }
        guard units <= snapshot.maxBolusUnits else { throw BolusError.exceedsMax(snapshot.maxBolusUnits) }
        snapshot.connection = .bolusing; onChange?()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        snapshot.connection = .connected
        snapshot.iobUnits += units
        snapshot.lastBolusUnits = units
        snapshot.lastBolusDate = Date()
        onChange?()
        return units
    }

    public func cancelBolus() async {
        snapshot.connection = .connected; onChange?()
    }
}
