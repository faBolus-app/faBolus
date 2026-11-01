import Foundation
import PumpSession
import faBolusCore

/// The bolus result banner for an outcome (the S1 states). An unknown outcome is never called failed.
public struct BolusBanner: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case inProgress, success, warning }
    public let kind: Kind
    public let title: String
    public let message: String

    public static let unknownMessage = "Bolus sent but outcome is unknown — verify on the pump before retrying."

    public static func make(_ outcome: BolusOutcome, requestedUnits: Double?) -> BolusBanner {
        let requested = requestedUnits.map { formatUnits($0) }
        switch outcome {
        case .requested, .accepted:
            return BolusBanner(kind: .inProgress, title: "Starting bolus", message: requested ?? "")
        case .delivering:
            return BolusBanner(
                kind: .inProgress, title: "Delivering", message: requested.map { "\($0) requested" } ?? "")
        case .delivered(let units):
            return BolusBanner(kind: .success, title: "Bolus delivered", message: "\(formatUnits(units)) delivered")
        case .stopped(let delivered, let req):
            return BolusBanner(
                kind: .warning, title: "Bolus stopped",
                message: "\(String(format: "%.2f", delivered)) of \(formatUnits(req)) delivered")
        case .refused(let reason), .failed(let reason):
            return BolusBanner(kind: .warning, title: "Bolus not delivered", message: reason)
        case .unknown:
            return BolusBanner(kind: .warning, title: "Bolus outcome unknown", message: unknownMessage)
        }
    }
}

/// What the phone offers for clearing a pump alert, from the one per-alert `remoteClear` value the
/// session sets, and what it says after an attempt.
public enum AlertClearOffer: Sendable, Equatable {
    /// This pump has accepted a clear: "Clear".
    case clear
    /// Not known yet for this pump: a secondary "Try clearing from phone".
    case tryFromPhone
    /// Clear it on the pump; no button.
    case clearOnPump

    public init(_ alert: PumpAlert) {
        switch alert.remoteClear {
        case .available: self = .clear
        case .tryable: self = .tryFromPhone
        case .unavailable: self = .clearOnPump
        }
    }

    public static let clearOnPumpText = "Clear it on the pump."
    public static let notClearedText = "The pump didn't clear it — clear it on the pump."

    /// What the phone says after trying to clear; `nil` once it's cleared.
    public static func message(after outcome: DismissOutcome) -> String? {
        switch outcome {
        case .cleared: return nil
        case .notCleared, .unsupported: return notClearedText
        case .refused: return "The pump refused to clear it — clear it on the pump."
        case .unconfirmed: return "The pump didn't answer. Check the pump; the alert may still be showing."
        }
    }
}

/// What the phone says about the pump link, a refused delivery or a cancel.
public enum PumpMessages {
    public static func text(_ failure: PumpLinkFailure) -> String {
        switch failure {
        case .pairingRejected: return "The pump rejected the pairing code. Pair again with a new code from the pump."
        case .unsupportedModel(let model):
            return model == .mobi
                ? "This is a Mobi, which faBolus doesn't connect to yet." : "faBolus can't connect to this pump."
        case .identityMismatch:
            return
                "A different pump answered under this pairing, so faBolus disconnected. Forget the pump and pair again."
        case .pumpNotFound: return "No pump found. Put the pump in pairing mode and keep it close to the phone."
        case .reconnectGaveUp:
            return "faBolus stopped trying to reconnect after repeated drops. It tries again when you open the app."
        }
    }

    public static func text(_ reason: PumpDisconnectReason) -> String {
        switch reason {
        case .requested: return "Disconnected."
        case .bluetoothUnavailable: return "Bluetooth is off or not allowed for faBolus."
        case .linkLost: return "The pump's Bluetooth link dropped. faBolus reconnects by itself."
        case .authenticationFailed: return "The pump didn't accept the pairing. faBolus tries again."
        case .afterUnsupportedRequest: return "The pump dropped the link after an unsupported request. Reconnecting."
        }
    }

    public static func text(_ refusal: DeliveryRefusal) -> String {
        switch refusal {
        case .notConnected: return "The pump isn't connected."
        case .pumpNotTrusted: return "The connected pump isn't the paired t:slim X2, so nothing was sent."
        case .blocked(let block): return block.userMessage
        case .requestIdReused: return "This request was already used for a different dose. Start again."
        case .notRecorded: return "The bolus couldn't be recorded on this phone, so it wasn't sent."
        case .invalidDose: return "The pump can't take that dose."
        }
    }

    public static func text(_ result: CancelResult) -> String {
        switch result {
        case .cancelled: return "Bolus cancelled."
        case .stoppedBeforeStart: return "Stopped before anything was delivered."
        case .notCancelled: return "The pump didn't cancel; the bolus may have finished. Check the pump."
        case .noBolus: return "The pump has no bolus in progress."
        case .notConnected: return "The pump isn't connected. Cancel on the pump."
        case .unconfirmed:
            return "The cancel wasn't confirmed. Check the pump, and cancel there if it's still delivering."
        }
    }
}
