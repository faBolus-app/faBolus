import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

@MainActor
@Suite struct DoseInputFixTests {
    /// The phone's clock set forward while a dose's reads wait: a reading from before the dose's reads
    /// still reads as from before them.
    @Test func aClockSetDuringTheDoseReadsMovesWhenTheyWereAskedFor() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(ControlIQIOBRequest.self)] = .silent
        let session = rig.session
        let preparation = Task { await session.prepareDose() }
        await rig.run(for: 5, step: 1)
        rig.clock.setWallClock(by: 3600)
        await rig.run(for: 70, step: 1)
        let prepared = try #require(await rig.value(of: preparation))
        let iob = try #require(prepared.pump.insulinOnBoard)
        #expect(iob.receivedAt < prepared.inputsRequestedAt)
    }

    /// A new CGM reading is followed by one read of the calculator snapshot, so the reading it carries is
    /// the new one within seconds; the same reading read again asks for nothing more.
    @Test func aNewCGMReadingIsFollowedByOneSnapshotRead() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        await rig.run(for: 5, step: 1)
        let before = rig.pump.arrivals(of: BolusCalcDataSnapshotRequest.self).count
        rig.pump.glucose = (150, 0)
        rig.transport.qualifyingEvents(.cgmChange)
        await rig.run(for: 3, step: 1)
        #expect(rig.pump.arrivals(of: BolusCalcDataSnapshotRequest.self).count == before + 1)
        let state = await rig.session.state
        #expect(state.bolusCalculator?.value.reading?.mgdl == 150)
        #expect(state.correctionReading?.value.mgdl == state.glucose?.value.mgdl)
        // The same reading, read again on a notice: no snapshot read.
        rig.transport.qualifyingEvents(.cgmChange)
        await rig.run(for: 3, step: 1)
        #expect(rig.pump.arrivals(of: BolusCalcDataSnapshotRequest.self).count == before + 1)
    }

    /// The dose's own read of the calculator snapshot comes first: a snapshot gone stale while the pump
    /// didn't answer asks that the limits can't be checked, and one the dose read again doesn't.
    @Test func theLimitsNotCheckedQuestionComesOnlyWhenTheDosesReadFails() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.bolusedLastHourMilliunits = 1_000
        })
        await rig.startHeld()
        let session = rig.session
        rig.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .silent
        await rig.run(for: 6 * 60, step: 30)
        func needed() async throws -> [DoseConfirmation.Kind] {
            let prepared = try #require(await rig.run(upTo: 200) { await session.prepareDose() })
            let access = AccessPolicy.AccessContext(
                phoneReadOnly: false, remotesReadOnly: false, capabilities: prepared.pump.capabilities)
            let context = prepared.context(access: access, remoteSizeLimitUnits: nil)
            return DoseComposer.confirmations(units: 1, context: context).map(\.kind)
        }
        #expect(try await needed().contains(.bolusLimitsNotChecked))
        rig.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .normal
        #expect(try await !needed().contains(.bolusLimitsNotChecked))
    }
}
