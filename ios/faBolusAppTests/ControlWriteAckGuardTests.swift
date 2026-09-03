import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// The enduring structural guard for the ack-inspecting `sendControl` funnel: fails if a signed
/// `.control` write is ever issued without its response being awaited via the coordinator — the exact
/// shape a regression back to fire-and-forget would take. Built from `FakePumpTransport`'s own
/// bookkeeping rather than a source-text scan: `sent` is recorded on both the fire-and-forget `send` and
/// the awaited `sendAwaitingResponse`, but `awaited` only on the latter, so a fire-and-forget signed
/// `.control` write is exactly a `sent`-without-`awaited` entry.
///
/// Scoped to the `.control` characteristic subset (narrower than "every signed opcode `sendControl`
/// sends" — the wider form is also valid and costs nothing while this funnel exists, but every message
/// `sendControl` sends is `.control` by construction, so the narrower form is equivalent here and reads
/// more directly as "every signed control write this backend can issue").
@Suite @MainActor
struct ControlWriteAckGuardTests {

    /// Every signed `.control` request `sendControl` can send, mapped to its response opcode. Mirrors
    /// `ControlAckInspection.swift`'s conformance list one-for-one; re-derive both from `sendControl(`
    /// call sites in `TandemBackend.swift` if this ever drifts.
    private static let controlRequestResponseOpcodes: [UInt8: UInt8] = [
        SuspendPumpingRequest.props.opCode: SuspendPumpingResponse.props.opCode,
        ResumePumpingRequest.props.opCode: ResumePumpingResponse.props.opCode,
        SetTempRateRequest.props.opCode: SetTempRateResponse.props.opCode,
        StopTempRateRequest.props.opCode: StopTempRateResponse.props.opCode,
        SetModesRequest.props.opCode: SetModesResponse.props.opCode,
        PlaySoundRequest.props.opCode: PlaySoundResponse.props.opCode,
        SetG6TransmitterIdRequest.props.opCode: SetG6TransmitterIdResponse.props.opCode,
        StartDexcomG6SensorSessionRequest.props.opCode: StartDexcomG6SensorSessionResponse.props.opCode,
        SetDexcomG7PairingCodeRequest.props.opCode: SetDexcomG7PairingCodeResponse.props.opCode,
        SetSensorTypeRequest.props.opCode: SetSensorTypeResponse.props.opCode,
        StopDexcomCGMSensorSessionRequest.props.opCode: StopDexcomCGMSensorSessionResponse.props.opCode,
        EnterChangeCartridgeModeRequest.props.opCode: EnterChangeCartridgeModeResponse.props.opCode,
        ExitChangeCartridgeModeRequest.props.opCode: ExitChangeCartridgeModeResponse.props.opCode,
        EnterFillTubingModeRequest.props.opCode: EnterFillTubingModeResponse.props.opCode,
        ExitFillTubingModeRequest.props.opCode: ExitFillTubingModeResponse.props.opCode,
        FillCannulaRequest.props.opCode: FillCannulaResponse.props.opCode,
        SetMaxBolusLimitRequest.props.opCode: SetMaxBolusLimitResponse.props.opCode,
        SetMaxBasalLimitRequest.props.opCode: SetMaxBasalLimitResponse.props.opCode,
        ChangeTimeDateRequest.props.opCode: ChangeTimeDateResponse.props.opCode,
        ChangeControlIQSettingsRequest.props.opCode: ChangeControlIQSettingsResponse.props.opCode,
        SetSleepScheduleRequest.props.opCode: SetSleepScheduleResponse.props.opCode,
        SetActiveIDPRequest.props.opCode: SetActiveIDPResponse.props.opCode,
        RenameIDPRequest.props.opCode: RenameIDPResponse.props.opCode,
        DeleteIDPRequest.props.opCode: DeleteIDPResponse.props.opCode,
        CreateIDPRequest.props.opCode: CreateIDPResponse.props.opCode,
        SetIDPSegmentRequest.props.opCode: SetIDPSegmentResponse.props.opCode,
        SetLowInsulinAlertRequest.props.opCode: SetLowInsulinAlertResponse.props.opCode,
        SetAutoOffAlertRequest.props.opCode: SetAutoOffAlertResponse.props.opCode,
        SetSiteChangeReminderRequest.props.opCode: SetSiteChangeReminderResponse.props.opCode,
        SetPumpAlertSnoozeRequest.props.opCode: SetPumpAlertSnoozeResponse.props.opCode,
        CgmHighLowAlertRequest.props.opCode: CgmHighLowAlertResponse.props.opCode,
        CgmOutOfRangeAlertRequest.props.opCode: CgmOutOfRangeAlertResponse.props.opCode,
        CgmRiseFallAlertRequest.props.opCode: CgmRiseFallAlertResponse.props.opCode,
    ]

    /// Drive every signed-control wrapper `TandemBackend` exposes, with an accepted ack scripted for
    /// every response opcode above (plus a fresh `TimeSinceResetResponse` per call, for
    /// `refreshSigningTimestamp`). Errors are swallowed — this fixture exists to populate `sent`/
    /// `awaited`, not to assert individual outcomes (that is `ControlWriteAckTests`'s job).
    private func driveEverySignedControlWrite(_ b: TandemBackend, _ fake: FakePumpTransport) async {
        // One TimeSinceResetResponse per sendControl call (there are more calls than distinct opcodes,
        // since add/modify/deleteProfileSegment all share SetIDPSegmentRequest/Response, and
        // startG6Session can issue two signed writes) — script generously.
        for _ in 0..<(Self.controlRequestResponseOpcodes.count + 4) {
            fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        }
        for (_, responseOpCode) in Self.controlRequestResponseOpcodes {
            fake.script(
                responseOpCode, .frame(FakePumpTransport.frame(opCode: responseOpCode, cargo: [0], signed: true)))
        }

        try? await b.suspendDelivery()
        try? await b.resumeDelivery()
        try? await b.setTempBasal(percent: 50, durationMinutes: 30)
        try? await b.stopTempBasal()
        try? await b.setMode(.sleepOn)
        try? await b.playFindMyPump()
        try? await b.startG6Session(transmitterId: "80CDGN", sensorCode: 1234)
        try? await b.startG7Session(pairingCode: 123456)
        try? await b.setSensorType(1)
        try? await b.stopCgmSession()
        try? await b.enterChangeCartridgeMode()
        try? await b.exitChangeCartridgeMode()
        try? await b.enterFillTubingMode()
        try? await b.exitFillTubingMode()
        try? await b.fillCannula(milliunits: 500)
        try? await b.setMaxBolus(units: 10)
        try? await b.setMaxBasal(unitsPerHour: 2)
        try? await b.syncTimeToNow()
        try? await b.setControlIQ(enabled: true, weightLbs: 150, totalDailyInsulinUnits: 40)
        try? await b.setSleepSchedule(slot: 0, enabled: true, activeDays: 0x7F, startMinute: 0, endMinute: 60)
        try? await b.setActiveProfile(idpId: 1)
        try? await b.renameProfile(idpId: 1, name: "renamed")
        try? await b.deleteProfile(idpId: 1)
        try? await b.createProfile(
            name: "new", basalRateUnitsPerHour: 1.0, carbRatioGramsPerUnit: 10, isf: 50, targetBg: 100,
            insulinDurationMinutes: 300)
        try? await b.addProfileSegment(
            idpId: 1, startTimeMinutes: 0, basalRateUnitsPerHour: 1.0, carbRatioGramsPerUnit: 10, isf: 50,
            targetBg: 100)
        try? await b.setLowInsulinAlert(thresholdUnits: 20)
        try? await b.setAutoOffAlert(enabled: true, durationMinutes: 60)
        try? await b.setSiteChangeReminder(enabled: true, days: 3, timeOfDayMinutes: 480)
        try? await b.setAlertSnooze(enabled: true, durationMinutes: 30)
        try? await b.setCgmHighLowAlert(alertType: 0, thresholdMgdl: 180, repeatMinutes: 15, enabled: true)
        try? await b.setCgmOutOfRangeAlert(enabled: true, delayMinutes: 20)
        try? await b.setCgmRiseFallAlert(alertType: 0, enabled: true, mgdlPerMin: 3)
    }

    @Test func everySentSignedControlWriteHasItsResponseAwaited() async {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.setPumpModelIdentityForTesting(pumpModelName: "Mobi", isMobi: true)

        await driveEverySignedControlWrite(b, fake)

        var checked = 0
        for entry in fake.sent where entry.signed {
            guard let responseOpCode = Self.controlRequestResponseOpcodes[entry.opCode] else { continue }
            checked += 1
            #expect(
                fake.awaited.contains(responseOpCode),
                "signed .control opcode \(entry.opCode) was written but its response opcode \(responseOpCode) was never awaited — this is exactly the fire-and-forget shape the funnel must not revert to"
            )
        }
        #expect(checked > 0, "sanity: the drive above must have actually issued signed control writes")
    }

    /// Non-vacuousness proof: with the real funnel, EVERY qualifying `sent` entry's response opcode is
    /// in `awaited`. Recorded here as a count assertion so a future edit that silently narrows coverage
    /// (e.g. a wrapper stops reaching `sendControl`) is visible as a coverage regression, not just a
    /// silently-smaller passing set.
    @Test func theGuardCoversEveryDeclaredControlRequestResponsePair() async {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.setPumpModelIdentityForTesting(pumpModelName: "Mobi", isMobi: true)

        await driveEverySignedControlWrite(b, fake)

        let sentSignedControlOpcodes = Set(fake.sent.filter { $0.signed }.map(\.opCode))
        let coveredOpcodes = sentSignedControlOpcodes.intersection(Self.controlRequestResponseOpcodes.keys)
        #expect(
            coveredOpcodes.count == Self.controlRequestResponseOpcodes.count,
            "expected every declared control request opcode to have been sent at least once; missing: \(Set(Self.controlRequestResponseOpcodes.keys).subtracting(sentSignedControlOpcodes))"
        )
    }
}
