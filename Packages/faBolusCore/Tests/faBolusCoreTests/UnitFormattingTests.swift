import Testing
import faBolusCore

/// R3-J: lock the unit-display format produced by the typed `formatUnits` funnel. The real guard is that
/// the parameter is `Double` (an `Int` argument is a COMPILE error, unlike raw `String(format:)`); this
/// just pins the rendered string. Values chosen to be exactly representable so the assertions are
/// platform-stable (no `x.xx5` half-rounding edge cases).
@Suite struct UnitFormattingTests {
    @Test func locksTheUnitDisplayFormat() {
        #expect(formatUnits(1.5) == "1.50 U")
        #expect(formatUnits(0) == "0.00 U")
        #expect(formatUnits(0.25) == "0.25 U")
        #expect(formatUnits(10.0) == "10.00 U")
        #expect(formatUnits(3.0, fractionDigits: 1) == "3.0 U")
        #expect(formatUnits(3.0, fractionDigits: 0) == "3 U")
    }
}
