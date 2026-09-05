import Testing
import Foundation
@testable import faBolusCore

/// Covers `GlucoseUnit`'s mg/dL format/parse round trip and threshold labels — the app's only
/// display unit (mmol/L display was removed as dead code; `AppSettings.glucoseDisplayUnit`
/// force-sets `.mgdl` unconditionally).
struct GlucoseUnitTests {

    // MARK: - format(mgdl:)

    @Test func formatMgdlIsPlainInteger() {
        #expect(GlucoseUnit.mgdl.format(mgdl: 124) == "124")
        #expect(GlucoseUnit.mgdl.format(mgdl: 54) == "54")
    }

    // MARK: - parse(_:)

    @Test func parseMgdlStrictInteger() {
        #expect(GlucoseUnit.mgdl.parse("128") == 128)
        #expect(GlucoseUnit.mgdl.parse("0") == 0)
    }

    @Test func parseNonNumericOrEmptyReturnsNilNeverZero() {
        #expect(GlucoseUnit.mgdl.parse("") == nil)
        #expect(GlucoseUnit.mgdl.parse("abc") == nil)
        // Explicitly: nil, never 0 — the hazard this parse funnel exists to prevent.
        #expect(GlucoseUnit.mgdl.parse("abc") != 0)
    }

    // MARK: - Round-trip

    @Test func roundTripWithinOneMgdl() {
        for x in [54, 70, 100, 124, 180, 250, 400] {
            let display = GlucoseUnit.mgdl.format(mgdl: x)
            let recovered = GlucoseUnit.mgdl.parse(display)
            #expect(recovered != nil)
            if let recovered { #expect(abs(recovered - x) <= 1) }
        }
    }

    // MARK: - thresholdLabel

    @Test func thresholdLabelMgdlIsPlainInteger() {
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.veryLow, unit: .mgdl) == "54")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.low, unit: .mgdl) == "70")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.high, unit: .mgdl) == "180")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.veryHigh, unit: .mgdl) == "250")
    }

    // MARK: - wireToken

    @Test func wireTokenEqualsRawValue() {
        #expect(GlucoseUnit.mgdl.wireToken == "mgdl")
    }
}
