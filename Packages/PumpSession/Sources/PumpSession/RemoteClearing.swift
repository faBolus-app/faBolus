import TandemLink
import TandemMessages
import faBolusCore

/// A class of pump: a model at one API version, the unit `RemoteClearing.knownClasses` keys on.
public struct PumpClass: Sendable, Hashable {
    public let model: TandemMessages.PumpModel
    public let apiVersion: ApiVersion

    public init(model: TandemMessages.PumpModel, apiVersion: ApiVersion) {
        self.model = model
        self.apiVersion = apiVersion
    }
}

/// Whether an alert can be cleared from the phone or a remote: one decision, from the alert itself, what's
/// known for the pump's class, then this unit's own result.
public enum RemoteClearing {
    /// Whether each class of pump acts on a remote clear (DismissNotification, op-184), as the bench or the
    /// field settled it; a row replaces the trial for that class. A t:slim at API 4.0 refuses the opcode
    /// itself: P3's history logged it as BAD_OPCODE, and the pump dropped the link after it, so the trial
    /// there would only cost a drop. Other t:slims still try once (`docs/UNVERIFIED-GUESSES.md` #18).
    public static let knownClasses: [PumpClass: RemoteClearEvidence] = [
        PumpClass(model: .tslim, apiVersion: ApiVersion(major: 4, minor: 0)): .doesNotClear
    ]

    /// The answer for `alert`. `classAnswer` comes first; `unitAnswer` (the trial's result) only counts
    /// while the class has none.
    public static func decide(
        _ alert: PumpAlert, classAnswer: RemoteClearEvidence?, unitAnswer: RemoteClearEvidence?
    ) -> RemoteClear {
        guard alert.isDismissable, !alert.isMalfunction else { return .unavailable }
        switch classAnswer ?? unitAnswer {
        case .clears: return .available
        case .doesNotClear: return .unavailable
        case nil: return .tryable
        }
    }
}
