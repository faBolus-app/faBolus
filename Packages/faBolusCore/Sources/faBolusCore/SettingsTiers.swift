import Foundation

/// P14 Slice 1 — the two vocabulary axes the mode/settings system is built on. They live in faBolusCore
/// (not the app target) because the P8 access evaluator consumes them next: S2 threads `AppMode` +
/// `SettingTier` into `AccessPolicy.ModeGateContext` so modes become "one more input to the one
/// evaluator", never a sixth parallel gate. S1 introduces them as pure data — no enforcement, no UI.
///
/// Kept deliberately separate from the *provenance* vocabulary (`consensus-default / clinician-set /
/// self-set`, S7): tier is about **who may edit** a setting; provenance is about **who last set its
/// value**. A clinician-tier setting whose value is still the consensus default has tier `.clinician`
/// and provenance `.consensusDefault` — two different questions.

/// The experience tier a user is currently in. Fresh installs — and, per the owner decision (2026-08-06),
/// existing upgraded users — start at `.simple` and re-earn `.advanced` through the guided Objectives
/// sequence (S3), with an expert opt-out that jumps straight to `.advanced` behind a warning. There is no
/// fourth "expert" mode: the opt-out is a *path to* `.advanced`, not a distinct tier.
public enum AppMode: String, Codable, Sendable, CaseIterable, Comparable {
    case simple
    case standard
    case advanced

    /// Fresh-install / post-upgrade default (owner-locked: everyone starts at Simple).
    public static let installDefault: AppMode = .simple

    /// Increasing capability: `.simple < .standard < .advanced`. Lets a descriptor be gated by a
    /// *minimum* mode (`activeMode >= descriptor.minMode`) as well as by an explicit `Set<AppMode>`.
    private var rank: Int {
        switch self { case .simple: return 0; case .standard: return 1; case .advanced: return 2 }
    }
    public static func < (lhs: AppMode, rhs: AppMode) -> Bool { lhs.rank < rhs.rank }

    /// Human-facing label (English; localization lands with the mode/Objectives copy in a later slice).
    public var title: String {
        switch self {
        case .simple: return "Simple"
        case .standard: return "Standard"
        case .advanced: return "Advanced"
        }
    }
}

/// Editability tier of a setting — **who may set its value**, per §8's third axis (alongside branch and
/// mode) and §13's rule that clinician-tier settings stay accessible without a clinician, behind a
/// one-time acknowledgment (S8) rather than a hard lock.
///
/// - `.user`     — an app preference the user owns outright (no friction). All 44 current `AppSettings`
///                 keys are `.user`: they are app/display/remote preferences, not therapy parameters.
/// - `.clinician`— a therapy parameter conventionally set with clinical guidance. Editable behind the
///                 §2.1 one-time acknowledgment; **never a hard lock, never a `DenialReason`** (S8).
/// - `.fixed`    — not user-editable at all (a published constant / rate-of-change band). The UI must
///                 render it read-only, not merely default it.
///
/// The `.clinician` / `.fixed` tiers are reserved for the *pump therapy* descriptors that S6–S8 add;
/// they carry no behavior in S1 beyond being declarable.
public enum SettingTier: String, Codable, Sendable, CaseIterable {
    case user
    case clinician
    case fixed
}
