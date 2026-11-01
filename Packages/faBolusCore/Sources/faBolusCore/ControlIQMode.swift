import Foundation

/// The Control-IQ activity the pump reports: `0 = normal, 1 = sleep, 2 = exercise`.
///
/// Typed because the command that changes the mode uses a different numbering (`1 = sleep on`,
/// `2 = sleep off`, …), so a bare `Int` invites mixing a state up with a command. This release only
/// reads the mode.
public enum ControlIQActivity: Int, Sendable, Hashable, Codable, CaseIterable {
    case normal = 0
    case sleep = 1
    case exercise = 2

    /// Decodes any raw mode, reading an unknown value as `.normal`, the safe display default.
    public init(rawMode: Int) { self = ControlIQActivity(rawValue: rawMode) ?? .normal }
}
