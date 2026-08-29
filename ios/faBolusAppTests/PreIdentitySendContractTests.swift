import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// No pre-identity send — scheduler bootstrap or pairing/history reconciliation — may be
/// model-restricted, or reconnection deadlocks waiting for the identity those reads establish.
@Suite @MainActor
struct PreIdentitySendContractTests {

    @Test func noPreIdentitySendIsEverModelRestricted() {
        let scheduler = PumpReadScheduler()
        var captured: [any Message] = []
        scheduler.send = { msg in captured.append(msg); return 0 }
        scheduler.isConnected = { true }
        scheduler.startPollingForTesting()   // bootstrap trio + fastRead(includingIdentityGatedReads:false) + staticRead()
        scheduler.alertRead()                // deferred burst — captured directly; stopAllTimers cannot cancel asyncAfter

        // Paths PumpReadScheduler does not own. Re-derive if pairing / history-status / reconciliation
        // send sites change: Jpake + challenge handshake, HistoryLogStatus from TimeSinceReset, and
        // lastBolusStatus / HistoryLogRequest pages from indeterminate reconciliation.
        let outOfSchedulerPaths: [any Message] = [
            Jpake1aRequest(), Jpake1bRequest(), Jpake2Request(), Jpake3SessionKeyRequest(), Jpake4KeyConfirmationRequest(),
            CentralChallengeRequest(), PumpChallengeRequest(),
            HistoryLogStatusRequest(), HistoryLogRequest(startLog: 0, numberOfLogs: 1), LastBolusStatusV2Request(),
        ]

        #expect(!captured.isEmpty,
                "the dynamic capture must have actually captured something from the real scheduler — an empty capture would make this test vacuously true")

        let client = PumpBLEClient()   // fresh, unidentified: connectedPumpModel == nil, identityTrusted == false
        for message in captured + outOfSchedulerPaths {
            #expect(client.identityGateError(for: message) == nil,
                    "\(type(of: message)) (opcode \(message.opCode)) must never be refused pre-identity — reconnection would deadlock")
        }
    }
}
