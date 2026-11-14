import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

/// The last-bolus record by t:connect's version table: form C at API 3.1 or later, B below.
@MainActor
@Suite struct LastBolusFormTests {
    @Test func atAPI4AFinishedBolusIsSettledFromFormC() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.apiVersion = (major: 4, minor: 0)
        })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(1.0))
        await rig.run(for: rig.pump.pendingSeconds + 60)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
        #expect(rig.pump.arrivals(of: LastBolusStatusV3Request.self).count == 1)
        #expect(rig.pump.arrivals(of: LastBolusStatusV2Request.self).isEmpty)
    }

    /// A record still stopping may not have its final amount, so it settles nothing: history does.
    @Test func aStoppingRecordIsLeftToHistory() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.apiVersion = (major: 4, minor: 0)
        })
        await rig.startHeld()
        var stopping = [UInt8](repeating: 0, count: 53)
        stopping[0] = 1
        stopping[1] = 3
        stopping.replaceSubrange(2..<4, with: le16(rig.pump.nextBolusId))
        stopping.replaceSubrange(10..<14, with: le32(500))
        rig.pump.answers[MessageKey(LastBolusStatusV3Request.self)] = .cargo(stopping)
        _ = await rig.session.deliver(composed(1.0))
        await rig.run(for: rig.pump.pendingSeconds + 60)
        #expect(rig.pump.arrivals(of: LastBolusStatusV3Request.self).count == 1)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }

    @Test func atAPI2Point5ItIsFormB() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(1.0))
        await rig.run(for: rig.pump.pendingSeconds + 60)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
        #expect(rig.pump.arrivals(of: LastBolusStatusV3Request.self).isEmpty)
        #expect(rig.pump.arrivals(of: LastBolusStatusV2Request.self).count == 1)
    }
}

/// Bit 31, bolus permission revoked.
@MainActor
@Suite struct PermissionRevokedTests {
    /// Before InitiateBolus is queued, the delivery stops there: no InitiateBolus, the permission released.
    @Test func aRevokedPermissionStopsADeliveryBeforeItStarts() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(RemoteBgEntryRequest.self)] = .silent
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0, bg: 180)) }
        #expect(await rig.until { rig.pump.arrivals(of: RemoteBgEntryRequest.self).count == 1 })
        rig.transport.qualifyingEvents(.bolusPermissionRevoked)
        await rig.run(for: 62)
        let result = await rig.value(of: delivery)
        #expect(result == .started(key, .failed(reason: PumpSession.permissionRevokedReason)))
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(rig.pump.released.count == 1)
    }

    /// Once InitiateBolus is out, the bolus is the pump's: bit 31 changes nothing here.
    @Test func aRevokedPermissionAfterInitiateLeavesTheBolusToThePump() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(1.0))
        rig.transport.qualifyingEvents(.bolusPermissionRevoked)
        await rig.run(for: rig.pump.pendingSeconds + 60)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }
}

/// The calculator reply's own reading: placed by the pump clock from its reading time, and only when the
/// reply marks it valid (guess #36).
@Suite struct CalculatorReadingReadTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(mgdl: Int, at pumpTime: UInt32, status: UInt8) -> BolusCalcDataSnapshotResponse {
        var v = [UInt8](repeating: 0, count: 46)
        v.replaceSubrange(1..<3, with: le16(mgdl))
        v.replaceSubrange(11..<13, with: le16(40))
        v.replaceSubrange(26..<30, with: le32(pumpTime))
        v[34] = status
        return BolusCalcDataSnapshotResponse(cargo: v)
    }

    private func reading(
        _ m: BolusCalcDataSnapshotResponse, anchor: PumpClockAnchor?
    ) -> BolusCalculatorSettings.Reading? {
        var state = PumpState()
        var alerts = PumpAlertLists()
        var basal = PumpBasalParts()
        _ = PumpReadings.apply(
            m, to: &state, alerts: &alerts, basal: &basal, context: .init(receivedAt: now, anchor: anchor))
        return state.bolusCalculator?.value.reading
    }

    @Test func aValidReadingIsPlacedByThePumpClock() {
        let anchor = PumpClockAnchor(pumpTime: 500_000_000, phoneTime: now)
        let r = reading(snapshot(mgdl: 150, at: 500_000_000 - 240, status: 1), anchor: anchor)
        #expect(r == .init(mgdl: 150, measuredAt: now.addingTimeInterval(-240)))
        let low = reading(snapshot(mgdl: 40, at: 500_000_000 - 60, status: 2), anchor: anchor)
        #expect(low?.outOfRange == .low)
    }

    @Test func anInvalidOrUnplaceableReadingIsNone() {
        let anchor = PumpClockAnchor(pumpTime: 500_000_000, phoneTime: now)
        #expect(reading(snapshot(mgdl: 150, at: 500_000_000 - 60, status: 0), anchor: anchor) == nil)
        #expect(reading(snapshot(mgdl: 150, at: 500_000_000 - 60, status: 4), anchor: anchor) == nil)
        #expect(reading(snapshot(mgdl: 0, at: 500_000_000 - 60, status: 1), anchor: anchor) == nil)
        #expect(reading(snapshot(mgdl: 150, at: 0, status: 1), anchor: anchor) == nil)
        #expect(reading(snapshot(mgdl: 150, at: 500_000_000 - 60, status: 1), anchor: nil) == nil)
    }
}
