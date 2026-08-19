import Foundation

/// Phase 09.23 (D-07/D-12): the ONE shared origin-tag metadata key faBolus stamps on every
/// HealthKit sample it writes (`HealthKitExporter`) and filters out on import
/// (`HealthKitHistoryImporter`) so faBolus never re-imports its own exported writes — the
/// echo-guard. Defined ONCE here; both services reference this constant, never duplicate the
/// literal (D-07 "define once").
///
/// Source: MIT-ported idiom from `github.com/LoopKit/LoopKit`,
/// `LoopKit/InsulinKit/HKQuantitySample+InsulinKit.swift` (`MetadataKeyHasLoopKitOrigin`), adapted
/// to faBolus's own key namespace.
enum HealthKitOriginTag {
    static let key = "com.fabolus.app.origin"
}
