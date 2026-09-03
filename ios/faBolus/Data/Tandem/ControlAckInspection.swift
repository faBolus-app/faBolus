import Foundation
import TandemMessages

/// App-only acceptance signal for a pump's ack to a `TandemBackend.sendControl` write. `status`/
/// `accepted` are per-type fields on the individual TandemKit response structs, never protocol members
/// (`Message`/`ResponseMessage` declare neither) — this protocol lets `sendControl` ask "did the pump
/// accept this?" uniformly across every response it can receive, without reading `cargo` generically or
/// trusting a bare `status == 0` where the type's own `accepted` says otherwise. Lives in the app, not
/// TandemKit: no kit file changes, no wire-byte changes.
///
/// Every conformance below is retroactive and additive — it teaches this app-only protocol about an
/// existing TandemKit type, changing nothing about that type's own decoding.
protocol ControlAck {
    /// Whether the pump accepted the write this ack answers. For a response exposing its own computed
    /// `accepted`, that value; for a status-only response, `status == 0`.
    var isControlAckAccepted: Bool { get }
    /// A short human noun for the write this ack answers (e.g. "sleep-schedule change", "suspend"), used
    /// to build a refusal message as specific as the ones it replaces.
    var controlAckSubjectDescription: String { get }
    /// The raw status code, for a refusal message that names it.
    var controlAckStatus: Int { get }
}

// MARK: - Responses exposing their own computed `accepted`

extension SuspendPumpingResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "suspend" }
    var controlAckStatus: Int { status }
}
extension ResumePumpingResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "resume" }
    var controlAckStatus: Int { status }
}
extension SetTempRateResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "temporary basal rate change" }
    var controlAckStatus: Int { status }
}
extension StopTempRateResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "temporary basal rate stop" }
    var controlAckStatus: Int { status }
}
extension SetModesResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "pump mode change" }
    var controlAckStatus: Int { status }
}
extension PlaySoundResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "find-my-pump sound" }
    var controlAckStatus: Int { status }
}
extension StartDexcomG6SensorSessionResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "G6 sensor session start" }
    var controlAckStatus: Int { status }
}
extension SetDexcomG7PairingCodeResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "G7 pairing code" }
    var controlAckStatus: Int { status }
}
extension SetSensorTypeResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "CGM sensor type change" }
    var controlAckStatus: Int { status }
}
extension StopDexcomCGMSensorSessionResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "CGM sensor session stop" }
    var controlAckStatus: Int { status }
}
extension EnterChangeCartridgeModeResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "cartridge-change mode entry" }
    var controlAckStatus: Int { status }
}
extension ExitChangeCartridgeModeResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "cartridge-change mode exit" }
    var controlAckStatus: Int { status }
}
extension EnterFillTubingModeResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "fill-tubing mode entry" }
    var controlAckStatus: Int { status }
}
extension ExitFillTubingModeResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "fill-tubing mode exit" }
    var controlAckStatus: Int { status }
}
extension FillCannulaResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "cannula fill" }
    var controlAckStatus: Int { status }
}
extension SetMaxBolusLimitResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "max-bolus limit change" }
    var controlAckStatus: Int { status }
}
extension SetMaxBasalLimitResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "max-basal limit change" }
    var controlAckStatus: Int { status }
}
extension ChangeTimeDateResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "pump clock change" }
    var controlAckStatus: Int { status }
}
extension SetActiveIDPResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "active profile switch" }
    var controlAckStatus: Int { status }
}
extension SetLowInsulinAlertResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "low-insulin alert threshold change" }
    var controlAckStatus: Int { status }
}
extension SetAutoOffAlertResponse: ControlAck {
    var isControlAckAccepted: Bool { accepted }
    var controlAckSubjectDescription: String { "auto-off alert change" }
    var controlAckStatus: Int { status }
}

// MARK: - Status-only responses (the generated block) — gate on `status == 0` only, never `cargo`
// directly, and never via `init(cargo:)`. Reaching one of these via `awaitControlResponse` already means
// `ResponseParser.parse` validated its length + HMAC first, so the short-buffer fail-open these types'
// own `init(cargo:)` has is unreachable on this path.

extension SetG6TransmitterIdResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "G6 transmitter ID" }
    var controlAckStatus: Int { status }
}
extension ChangeControlIQSettingsResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "Control-IQ settings change" }
    var controlAckStatus: Int { status }
}
extension SetSleepScheduleResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "sleep-schedule change" }
    var controlAckStatus: Int { status }
}
extension RenameIDPResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "profile rename" }
    var controlAckStatus: Int { status }
}
extension DeleteIDPResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "profile delete" }
    var controlAckStatus: Int { status }
}
extension CreateIDPResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "profile create" }
    var controlAckStatus: Int { status }
}
extension SetIDPSegmentResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "profile segment change" }
    var controlAckStatus: Int { status }
}
extension SetSiteChangeReminderResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "site-change reminder change" }
    var controlAckStatus: Int { status }
}
extension SetPumpAlertSnoozeResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "alert-snooze change" }
    var controlAckStatus: Int { status }
}
extension CgmHighLowAlertResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "CGM high/low alert change" }
    var controlAckStatus: Int { status }
}
extension CgmOutOfRangeAlertResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "CGM out-of-range alert change" }
    var controlAckStatus: Int { status }
}
extension CgmRiseFallAlertResponse: ControlAck {
    var isControlAckAccepted: Bool { status == 0 }
    var controlAckSubjectDescription: String { "CGM rise/fall alert change" }
    var controlAckStatus: Int { status }
}
