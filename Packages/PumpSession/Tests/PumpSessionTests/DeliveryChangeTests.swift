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
}
