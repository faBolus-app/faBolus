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
    /// field settled it. Empty for the t:slim until the bench check settles it (`docs/UNVERIFIED-GUESSES.md`
    /// #18); a row then replaces the trial for that class.
    public static let knownClasses: [PumpClass: RemoteClearEvidence] = [:]

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
