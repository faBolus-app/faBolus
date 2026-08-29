import Testing
import Foundation
@testable import faBolus

/// The carb→Int conversion inside `TandemBackend.perform(...)` must NEVER
/// trap. It runs AFTER a durable ledger commit, so a runtime trap here strands an already-recorded
/// delivery. The clamp lives in `TandemBackend.clampCarbGrams(_:)` so it can be
/// exercised directly. The load-bearing invariant: for EVERY input — `nil`, negative, out-of-range
/// finite (> `Int.max`), `.infinity`, `-.infinity`, `.nan` — the helper returns a value in `0...1000`
/// and does not crash. `maxCarbGrams == 1000`.
@MainActor
struct CarbBoundInvariantTests {

    private static let upperBound = 1000

    // MARK: - Point behaviors

    @Test func nilCarbsClampsToZero() {
        #expect(TandemBackend.clampCarbGrams(nil) == 0)
    }

    @Test func normalValuesRoundToNearestInt() {
        #expect(TandemBackend.clampCarbGrams(30.4) == 30)  // rounds down
        #expect(TandemBackend.clampCarbGrams(45.6) == 46)  // rounds up
        #expect(TandemBackend.clampCarbGrams(0) == 0)
    }

    @Test func upperBoundIsInclusive() {
        #expect(TandemBackend.clampCarbGrams(1000) == 1000)
    }

    @Test func aboveUpperBoundClampsToMax() {
        #expect(TandemBackend.clampCarbGrams(1001) == 1000)
    }

    @Test func negativeClampsToZero() {
        #expect(TandemBackend.clampCarbGrams(-5) == 0)
    }

    // MARK: - Non-finite inputs must not trap

    @Test func infinityClampsToZero() {
        #expect(TandemBackend.clampCarbGrams(.infinity) == 0)
    }

    @Test func negativeInfinityClampsToZero() {
        #expect(TandemBackend.clampCarbGrams(-.infinity) == 0)
    }

    @Test func nanClampsToZero() {
        #expect(TandemBackend.clampCarbGrams(.nan) == 0)
    }

    // MARK: - Finite values larger than Int.max must clamp, not trap

    @Test func finiteValuesBeyondIntMaxClampToMaxWithoutTrapping() {
        // These would trap `Int($0.rounded())` if the clamp happened after the conversion (the pre-fix bug).
        #expect(TandemBackend.clampCarbGrams(Double(Int.max)) == 1000)
        #expect(TandemBackend.clampCarbGrams(Double(Int.max) * 2) == 1000)
        #expect(TandemBackend.clampCarbGrams(.greatestFiniteMagnitude) == 1000)
    }

    // MARK: - The invariant: result is ALWAYS in 0...1000 and never traps

    @Test func resultAlwaysWithinBoundsForEveryInput() {
        let inputs: [Double?] = [
            nil, 0, 0.4, 0.5, 30.4, 45.6, 999, 999.9, 1000, 1000.4, 1001, 5000,
            -0.1, -5, -1000,
            .infinity, -.infinity, .nan,
            Double(Int.max), Double(Int.min), Double(Int.max) * 2,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude
        ]
        for input in inputs {
            let result = TandemBackend.clampCarbGrams(input)
            #expect(
                (0...Self.upperBound).contains(result),
                "clampCarbGrams(\(String(describing: input))) = \(result) escaped 0...\(Self.upperBound)")
        }
    }
}
