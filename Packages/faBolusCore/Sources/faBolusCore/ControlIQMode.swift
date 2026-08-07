import Foundation

/// P13c-4 — the pump user-mode bitmap collision, typed away.
///
/// The Tandem wire protocol overloads small integers in a genuinely dangerous way: the *reported*
/// Control-IQ activity STATE is `0 = normal, 1 = sleep, 2 = exercise` (`PumpSnapshot.controlIQMode`),
/// while the *command* that CHANGES it is a different bitmap — `1 = sleep on, 2 = sleep off,
/// 3 = exercise on, 4 = exercise off`. So the bare integer `1` means "sleep is active" as a state but
/// "turn sleep ON" as a command, and `2` means "exercise is active" as a state but "turn sleep OFF" as a
/// command. Passing a raw `Int` through the seam invites exactly the state↔command mix-up that would
/// send the wrong mode change. These two enums make the seam type-checked instead.
///
/// faBolusCore stays pump-neutral (it must not import the PumpX2 message layer), so this mirrors the
/// kit's own `SetModesRequest.ModeCommand` the way `PumpFeatureBits` mirrors the feature bitmask — the
/// driver translates the neutral command to the wire request. The raw values are kept identical to the
/// wire bitmap (1…4) so the driver's translation is a pure pass-through.

/// A pump user-mode COMMAND — what to change. Distinct type from the reported `ControlIQActivity` state.
public enum ModeCommand: Int, Sendable, Equatable, CaseIterable {
    case sleepOn = 1
    case sleepOff = 2
    case exerciseOn = 3
    case exerciseOff = 4

    /// The 1-byte wire bitmap the driver sends (identical to the raw value; the kit's `SetModesRequest`
    /// takes this bitmap and its own `ModeCommand` uses the same numbering — do not renumber).
    public var bitmap: Int { rawValue }
}

/// The reported Control-IQ activity STATE (`PumpSnapshot.controlIQMode`). Typed so state `0/1/2` is never
/// confused with the `ModeCommand` bitmap `1/2/3/4`.
public enum ControlIQActivity: Int, Sendable, Equatable, CaseIterable {
    case normal = 0
    case sleep = 1
    case exercise = 2

    /// Total (never-failing) decode of the raw `controlIQMode` int — an unknown value reads as `.normal`
    /// (the safe display default), never a crash.
    public init(rawMode: Int) { self = ControlIQActivity(rawValue: rawMode) ?? .normal }

    /// The command that clears this activity back to normal, or nil when already normal.
    public var clearCommand: ModeCommand? {
        switch self {
        case .normal:   return nil
        case .sleep:    return .sleepOff
        case .exercise: return .exerciseOff
        }
    }
}

/// The two **inverse** Control-IQ preconditions the firmware enforces, expressed as pre-flight checks so
/// the app refuses (with a plain reason) BEFORE the write instead of letting the pump silently reject it.
///
/// - Sleep/Exercise **modes** require Control-IQ to be **ON** (they only shape the controller's targets).
/// - A **temp rate** requires Control-IQ to be **OFF** (the controller owns basal while it's running).
///
/// Pure and pump-neutral: the UI can call these to disable+explain proactively, and the delivery funnel
/// calls them to fail closed. `nil` = allowed; a non-nil string = the reason it's blocked.
public enum ControlIQPrecondition {
    /// Modes need Control-IQ on.
    public static func modeBlockReason(controlIQEnabled: Bool) -> String? {
        controlIQEnabled ? nil : "Turn Control-IQ on to use Sleep or Exercise mode."
    }
    /// A temp rate needs Control-IQ off.
    public static func tempRateBlockReason(controlIQEnabled: Bool) -> String? {
        controlIQEnabled ? "Turn Control-IQ off to set a temporary basal rate." : nil
    }

    /// P14 S11 (§2.1(7)): the firmware + Control-IQ-version compatibility pre-flight for the
    /// `setControlIQ` **configuration** write. Refuses (with a plain reason) BEFORE the write when the
    /// connected pump can't take a remote Control-IQ configuration, rather than letting the pump silently
    /// reject it — mirroring the two inverse preconditions above.
    ///
    /// The authoritative signal is `supportsControlIQConfig` — whether the pump exposes *remote*
    /// Control-IQ configuration at all. It is `false` on t:slim X2 (which runs Control-IQ but Tandem only
    /// lets you configure it on the pump itself) and on any pump whose P13b feature bitmask / model
    /// doesn't advertise it; `true` on Mobi. `controllerVariant` is used ONLY to make the refusal message
    /// specific — it is **not** a gate, because `.none` is the normal state whenever the pump's feature
    /// bits haven't been read yet (the fallback / pre-`staticRead` path, and the simulator), so blocking
    /// a configurable pump on `.none` would wrongly refuse a legitimate Mobi write. Per P13's
    /// "absent capability ⇒ don't fail-block" rule, a configurable pump proceeds regardless of variant.
    ///
    /// `nil` = the write is compatible; a non-nil string = the reason it's blocked. Applies symmetrically
    /// to enabling and disabling: if the pump can't take the config write remotely, neither direction can.
    public static func configBlockReason(supportsControlIQConfig: Bool,
                                         controllerVariant: ControllerVariant) -> String? {
        guard !supportsControlIQConfig else { return nil }
        // Not remotely configurable. If the pump nonetheless HAS a Control-IQ controller (t:slim X2), say
        // so specifically; otherwise it has no Control-IQ controller at all.
        return controllerVariant == .none
            ? "This pump doesn't support Control-IQ."
            : "Control-IQ can only be changed on the pump itself for this model."
    }
}
