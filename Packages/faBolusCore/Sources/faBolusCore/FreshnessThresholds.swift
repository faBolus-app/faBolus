import Foundation

/// How old each kind of reading may be before it stops counting as current. A value, passed to whatever
/// decides, rather than a process-wide setting: the pump session holds the user's choice and hands it to
/// the dose path and the display, so two decisions made at the same moment can't read different windows.
public struct FreshnessThresholds: Sendable, Hashable, Codable {
    /// Glucose older than this is stale: shown marked, never as current, and never fills a correction.
    public var glucoseStaleAfter: TimeInterval
    /// Age at which a stale glucose reading is hidden instead of shown marked. `nil` never hides. Never
    /// earlier than `glucoseStaleAfter`.
    public var glucoseHideAfter: TimeInterval?
    /// The oldest a stale reading may be and still be included in a correction when the user asks for it
    /// (LoopKit's 15-minute `inputDataRecencyInterval`). Older readings fall back to carbs only.
    public var maxIncludableGlucoseAge: TimeInterval
    /// IOB older than this isn't used without a prompt.
    public var insulinOnBoardStaleAfter: TimeInterval
    /// Calculator settings older than this aren't used without a prompt.
    public var therapyStaleAfter: TimeInterval
    /// The pump's status values (reservoir, battery, basal) older than this are shown marked as stale. Display
    /// only: no dose decision reads it.
    public var pumpStatusStaleAfter: TimeInterval

    public init(
        glucoseStaleAfter: TimeInterval = 6 * 60, glucoseHideAfter: TimeInterval? = nil,
        maxIncludableGlucoseAge: TimeInterval = 15 * 60, insulinOnBoardStaleAfter: TimeInterval = 5 * 60,
        therapyStaleAfter: TimeInterval = 15 * 60, pumpStatusStaleAfter: TimeInterval = 15 * 60
    ) {
        self.glucoseStaleAfter = glucoseStaleAfter
        self.glucoseHideAfter = glucoseHideAfter
        self.maxIncludableGlucoseAge = maxIncludableGlucoseAge
        self.insulinOnBoardStaleAfter = insulinOnBoardStaleAfter
        self.therapyStaleAfter = therapyStaleAfter
        self.pumpStatusStaleAfter = pumpStatusStaleAfter
    }

    private enum CodingKeys: String, CodingKey {
        case glucoseStaleAfter, glucoseHideAfter, maxIncludableGlucoseAge, insulinOnBoardStaleAfter, therapyStaleAfter
        case pumpStatusStaleAfter
    }

    /// Thresholds saved before `pumpStatusStaleAfter` existed read with its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glucoseStaleAfter = try c.decode(TimeInterval.self, forKey: .glucoseStaleAfter)
        glucoseHideAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .glucoseHideAfter)
        maxIncludableGlucoseAge = try c.decode(TimeInterval.self, forKey: .maxIncludableGlucoseAge)
        insulinOnBoardStaleAfter = try c.decode(TimeInterval.self, forKey: .insulinOnBoardStaleAfter)
        therapyStaleAfter = try c.decode(TimeInterval.self, forKey: .therapyStaleAfter)
        pumpStatusStaleAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .pumpStatusStaleAfter) ?? 15 * 60
    }

    /// The defaults. A window that isn't a finite, non-negative number makes every reading stale.
    public static let standard = FreshnessThresholds()
}
