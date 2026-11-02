import Foundation
import RemoteProtocol
import Testing

@testable import RemoteHost
@testable import faBolusCore

/// The host's services from the app's real parts: the pump session over the scripted pump, the ledger,
/// the alert pipeline, and the app's backup CGM source and glucose history.
@MainActor
@Suite struct SessionRemoteServicesTests {
    /// A phone whose pump has no glucose reading, with this backup reading.
    func phone(backup mgdl: Int, ageSeconds: Double) async -> RelaunchingPhone {
        let phone = RelaunchingPhone(configure: { $0.glucose = nil })
        let clock = phone.clock
        phone.backupGlucose = {
            GlucoseSourceState(
                latest: GlucoseSample(mgdl: mgdl, date: clock.date.addingTimeInterval(-ageSeconds), sourceID: "backup"),
                status: .connected)
        }
        await phone.launch()
        return phone
    }

    /// A correction from 190 mg/dL: (190 - 110) / 40 less the pump's 0.5 U on board is 1.5 U.
    func correctionOnly(_ phone: RelaunchingPhone) async -> RemoteDoseDecision {
        await phone.process.services.compose(
            RemoteDoseRequest(
                id: "w1", peerId: "garmin", surface: .garmin, sentAt: phone.clock.date,
                amount: .calculator(carbsGrams: 0, estimateUnits: 1.5)),
            access: HostRig.settings().access, remoteSizeLimitUnits: nil)
    }

    /// The pump has no reading, so a fresh backup reading is shown, marked as the failover, and a
    /// correction is worked out from it.
    @Test func aFreshBackupReadingStandsInForTheMissingPumpReading() async {
        let phone = await phone(backup: 190, ageSeconds: 60)
        let (state, provenance) = await phone.process.services.pump()
        #expect(state.glucose?.value.mgdl == 190)
        #expect(provenance == .failover(sourceID: "backup", reason: .pumpMissing))
        guard case .deliver(let dose) = await correctionOnly(phone) else {
            Issue.record("expected a dose")
            return
        }
        #expect(dose.correctionGlucoseMgdl == 190)
    }

    /// A stale backup reading isn't taken as the current one, and never fills a correction: with nothing
    /// to correct from, there is no dose.
    @Test func aStaleBackupReadingNeverFillsACorrection() async {
        let phone = await phone(backup: 190, ageSeconds: 30 * 60)
        let (state, provenance) = await phone.process.services.pump()
        #expect(state.glucose == nil)
        #expect(provenance == .pump)
        if case .deliver(let dose) = await correctionOnly(phone) {
            #expect(dose.correctionGlucoseMgdl == nil)
        }
    }

    /// The watch's chart reads the app's glucose history.
    @Test func theGlucoseHistoryIsTheApps() async {
        let phone = RelaunchingPhone()
        let start = phone.clock.date
        let readings = [GlucoseReading(date: start.addingTimeInterval(-600), mgdl: 140)]
        phone.glucoseHistory = { since in readings.filter { $0.date >= since } }
        await phone.launch()
        #expect(await phone.process.services.glucoseHistory(since: start.addingTimeInterval(-3600)) == readings)
        #expect(await phone.process.services.glucoseHistory(since: start).isEmpty)
    }
}
