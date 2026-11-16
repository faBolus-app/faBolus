import Foundation
import PumpScript
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

/// The pump's basal rate changes, suspends and resumes reach the history store for the chart's basal line.
@MainActor
@Suite struct DeliveryChangeTests {
    @Test func basalChangesSuspendsAndResumesAreKeptForTheChart() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            let at = $0.wallClockAtStart
            // Basal Rate Change: the commanded rate, as a float in U/h, then the base and maximum rates.
            _ = $0.appendHistory(
                typeId: BasalRateChangeHistoryLog.typeId, at: at - 3600,
                body: Array(withUnsafeBytes(of: Float(0.85).bitPattern.littleEndian, Array.init))
                    + [UInt8](repeating: 0, count: 12))
            _ = $0.appendHistory(typeId: PumpingSuspendedHistoryLog.typeId, at: at - 1800, body: [])
            _ = $0.appendHistory(typeId: PumpingResumedHistoryLog.typeId, at: at - 1200, body: [])
        })
        await rig.startHeld()
        let session = rig.session
        let sync = Task { await session.syncHistory() }
        await rig.run(for: 6)
        await rig.value(of: sync)
        let changes = await rig.sink.batches.flatMap(\.deliveryChanges).sorted { $0.date < $1.date }
        #expect(changes.map(\.kind) == [.basalRate, .suspended, .resumed])
        #expect(changes.first?.unitsPerHour == Double(Float(0.85)))
        #expect(changes[1].date.timeIntervalSince(changes[0].date) == 1800)
    }

    /// With Control-IQ the pump writes few Basal Rate Change records; the Basal Delivery record it writes every
    /// five minutes carries the rate it commanded, in milliunits an hour. A rate is kept only when it changes,
    /// and suspension is left to the suspend and resume records.
    @Test func basalDeliveryRecordsDrawTheRateAsItChanges() async {
        func body(source: Int, rate: Int, profile: Int = 1000, algorithm: Int = 0xFFFF, temp: Int = 0xFFFF) -> [UInt8] {
            [source, 0, rate, profile, algorithm, temp].flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            let at = $0.wallClockAtStart
            let records: [(UInt32, [UInt8])] = [
                (1800, body(source: 3, rate: 600, algorithm: 600)),
                (1500, body(source: 3, rate: 600, algorithm: 600)),
                (1200, body(source: 3, rate: 750, algorithm: 750)),
                (900, body(source: 0, rate: 0, profile: 0xFFFF)),
                (600, body(source: 2, rate: 1600, temp: 1600)),
                (300, body(source: 1, rate: 0xFFFF)),
                (60, body(source: 1, rate: 1000))
            ]
            for (ago, b) in records {
                _ = $0.appendHistory(typeId: BasalDeliveryHistoryLog.typeId, at: at - ago, body: b)
            }
        })
        await rig.startHeld()
        let session = rig.session
        let sync = Task { await session.syncHistory() }
        await rig.run(for: 6)
        await rig.value(of: sync)
        let changes = await rig.sink.batches.flatMap(\.deliveryChanges).sorted { $0.date < $1.date }
        #expect(changes.map(\.kind) == [.basalRate, .basalRate, .basalRate, .basalRate])
        #expect(changes.map(\.unitsPerHour) == [0.6, 0.75, 1.6, 1.0])
        #expect(changes[1].date.timeIntervalSince(changes[0].date) == 600)
    }

    /// A Basal Rate Change between two equal Basal Delivery rates moves the line, so the second Basal Delivery
    /// record is kept to move it back.
    @Test func aBasalRateChangeBetweenEqualDeliveryRatesIsUndone() async {
        let delivery: [UInt8] = [3, 0, 0, 0] + [600, 1000, 600, 0xFFFF].flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            let at = $0.wallClockAtStart
            _ = $0.appendHistory(typeId: BasalDeliveryHistoryLog.typeId, at: at - 900, body: delivery)
            _ = $0.appendHistory(
                typeId: BasalRateChangeHistoryLog.typeId, at: at - 700,
                body: Array(withUnsafeBytes(of: Float(1.0).bitPattern.littleEndian, Array.init))
                    + [UInt8](repeating: 0, count: 12))
            _ = $0.appendHistory(typeId: BasalDeliveryHistoryLog.typeId, at: at - 600, body: delivery)
        })
        await rig.startHeld()
        let session = rig.session
        let sync = Task { await session.syncHistory() }
        await rig.run(for: 6)
        await rig.value(of: sync)
        let changes = await rig.sink.batches.flatMap(\.deliveryChanges).sorted { $0.date < $1.date }
        #expect(changes.map(\.unitsPerHour) == [0.6, 1.0, 0.6])
    }
}
