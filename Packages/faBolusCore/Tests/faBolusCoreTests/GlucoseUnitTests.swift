import Testing
import Foundation
@testable import faBolusCore

/// Covers `GlucoseUnit`'s 1-decimal mmol format, its nearest-mg/dL-Int parse (never truncated),
/// the round-trip bound, and the clinically-rounded threshold labels.
struct GlucoseUnitTests {

    // MARK: - format(mgdl:)

    @Test func formatMgdlIsPlainInteger() {
        #expect(GlucoseUnit.mgdl.format(mgdl: 124) == "124")
        #expect(GlucoseUnit.mgdl.format(mgdl: 54) == "54")
    }

    @Test func formatMmolIsExactlyOneDecimal() {
        // 124 / 18.0182 = 6.8807… → "6.9"
        #expect(GlucoseUnit.mmol.format(mgdl: 124) == "6.9")
        // 70 / 18.0182 = 3.8850… → "3.9"
        #expect(GlucoseUnit.mmol.format(mgdl: 70) == "3.9")
    }

    // MARK: - parse(_:)

    @Test func parseMgdlStrictInteger() {
        #expect(GlucoseUnit.mgdl.parse("128") == 128)
        #expect(GlucoseUnit.mgdl.parse("0") == 0)
    }

    @Test func parseMmolRoundsToNearestMgdl() {
        // 7.1 mmol/L × 18.0182 = 127.929… → rounds to 128, NOT truncated to 127.
        #expect(GlucoseUnit.mmol.parse("7.1") == 128)
    }

    @Test func parseMmolAcceptsCommaDecimalSeparator() {
        // `.decimalPad` presents a locale decimal separator (comma in
        // most mainland-Europe mmol/L locales). "7,1" must parse identically to "7.1" — same
        // nearest-mg/dL rounding, never a silent nil-drop of a correctly-typed correction.
        #expect(GlucoseUnit.mmol.parse("7,1") == GlucoseUnit.mmol.parse("7.1"))
        #expect(GlucoseUnit.mmol.parse("7,1") == 128)
    }

    @Test func parseNonNumericOrEmptyReturnsNilNeverZero() {
        #expect(GlucoseUnit.mgdl.parse("") == nil)
        #expect(GlucoseUnit.mgdl.parse("abc") == nil)
        #expect(GlucoseUnit.mmol.parse("") == nil)
        #expect(GlucoseUnit.mmol.parse("abc") == nil)
        // Explicitly: nil, never 0 — the hazard this parse funnel exists to prevent.
        #expect(GlucoseUnit.mmol.parse("abc") != 0)
    }

    // MARK: - Round-trip

    @Test func roundTripWithinOneMgdl() {
        for x in [54, 70, 100, 124, 180, 250, 400] {
            let display = GlucoseUnit.mmol.format(mgdl: x)
            let recovered = GlucoseUnit.mmol.parse(display)
            #expect(recovered != nil)
            if let recovered { #expect(abs(recovered - x) <= 1) }
        }
    }

    // MARK: - thresholdLabel

    @Test func thresholdLabelMmolUsesClinicalRounding() {
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.veryLow, unit: .mmol) == "3.0")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.low, unit: .mmol) == "3.9")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.high, unit: .mmol) == "10.0")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.veryHigh, unit: .mmol) == "13.9")
    }

    @Test func thresholdLabelMgdlIsPlainInteger() {
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.veryLow, unit: .mgdl) == "54")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.low, unit: .mgdl) == "70")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.high, unit: .mgdl) == "180")
        #expect(GlucoseUnit.thresholdLabel(GlucoseThresholds.veryHigh, unit: .mgdl) == "250")
    }

    // MARK: - wireToken

    @Test func wireTokenEqualsRawValue() {
        #expect(GlucoseUnit.mgdl.wireToken == "mgdl")
        #expect(GlucoseUnit.mmol.wireToken == "mmol")
    }
}
