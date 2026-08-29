import XCTest
@testable import faBolusCore

/// The faBolus glucose-unit shim for the LoopInsights endo report. Replaces the
/// mirror `LoopInsights_GlucoseUnitContext` (which imports LoopKit/LoopKitUI/HealthKit and carries
/// AI-prompt methods) with a thin wrapper over faBolusCore's own `GlucoseUnit`. NO AI-prompt
/// surface is ported: this only formats mg/dL values + the TIR range label in the user's unit.
final class InsightsGlucoseUnitContextTests: XCTestCase {

    func testMgdlFormatsPlainInteger() {
        let ctx = InsightsGlucoseUnitContext(unit: .mgdl)
        XCTAssertEqual(ctx.formatMgdl(180), "180")
        XCTAssertEqual(ctx.formatMgdl(180.0), "180")
        XCTAssertEqual(ctx.unitString, "mg/dL")
    }

    func testMmolFormatsOneDecimalViaGlucoseUnit() {
        let ctx = InsightsGlucoseUnitContext(unit: .mmol)
        // Must route through GlucoseUnit.format (1-decimal mmol/L), never re-derive the conversion.
        XCTAssertEqual(ctx.formatMgdl(180), GlucoseUnit.mmol.format(mgdl: 180))
        XCTAssertTrue(ctx.formatMgdl(180).contains("."), "mmol/L renders one decimal")
        XCTAssertEqual(ctx.unitString, "mmol/L")
    }

    func testTirRangeLabelMatchesUnit() {
        let mgdl = InsightsGlucoseUnitContext(unit: .mgdl)
        XCTAssertEqual(mgdl.tirRangeLabel, "Time in Range (70–180)")

        // mmol/L uses the clinically-conventional rounded threshold labels, not a raw conversion.
        let mmol = InsightsGlucoseUnitContext(unit: .mmol)
        XCTAssertEqual(mmol.lowThresholdLabel, "3.9")
        XCTAssertEqual(mmol.highThresholdLabel, "10.0")
        XCTAssertEqual(mmol.tirRangeLabel, "Time in Range (3.9–10.0)")
    }
}
