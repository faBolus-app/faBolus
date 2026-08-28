import Testing
import Foundation
@testable import faBolusCore

/// SYSTEMIC (09.18d code-review): the shared `clampedInt` funnel is the single guarded path for
/// converting an untrusted `Double` to an `Int`, replacing the raw `Int(_:)` that has trapped twice
/// (09.18c FoodFinder carb card, 09.18d caffeine tracker log). Every adversarial input that would trap
/// a bare `Int(Double)` must return a safe, in-range value instead of crashing.
@Suite struct ClampedIntTests {

    @Test func finiteInRangeRoundsToNearest() {
        #expect(clampedInt(0, max: 100) == 0)
        #expect(clampedInt(41.4, max: 100) == 41)
        #expect(clampedInt(41.6, max: 100) == 42)
        #expect(clampedInt(100, max: 100) == 100)
    }

    @Test func finiteOutOfRangeClampsToBounds() {
        #expect(clampedInt(-5, max: 100) == 0)  // below default min (0)
        #expect(clampedInt(250, max: 100) == 100)  // above max
        #expect(clampedInt(-5, min: 10, max: 100) == 10)  // below explicit min
    }

    /// The headline crash-class values: a bare `Int(_:)` on any of these traps.
    @Test func adversarialValuesDoNotTrap() {
        // 1e19 is finite but above Int.max (~9.2e18) → must clamp to max, not overflow-trap.
        #expect(clampedInt(1e19, max: 100_000) == 100_000)
        // +infinity, -infinity, and NaN are non-finite → floor (min), never a trap.
        #expect(clampedInt(.infinity, max: 100_000) == 0)
        #expect(clampedInt(-.infinity, max: 100_000) == 0)
        #expect(clampedInt(.nan, max: 100_000) == 0)
        // Double(Int.min) is finite but far below the floor → clamps to min, no trap.
        #expect(clampedInt(Double(Int.min), max: 100_000) == 0)
        // Non-finite with an explicit non-zero min returns that min.
        #expect(clampedInt(.nan, min: 7, max: 100_000) == 7)
    }
}
