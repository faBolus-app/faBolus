import XCTest
@testable import faBolusCore

/// Byte-for-byte parity of `BolusMath` against the vendored Tandem oracle `BolusCalculator.parse()`.
///
/// The fixtures in `Fixtures/bolus_oracle_fixtures.jsonl` were captured by running the **actual**
/// `BolusCalculator.java` (PumpX2Kit `vendor/pumpx2-oracle`, compiled bytecode) over a grid of inputs
/// that spans every branch of `parse()`: carbs / no carbs × BG below / at / above target × IOB below /
/// equal / above the correction × zero and floor boundaries, plus profile variations (carb ratio, ISF,
/// target) and sanity-failure edges (invalid carb ratio, ISF ≤ 0, target out of [40,400]). Each row is
/// `{carbs, bg, cr(g/U), isf, tgt, iob(U), u(oracle total)}`.
///
/// If this test fails, `BolusMath` has diverged from the pump calculator — do not ship a dosing change
/// until it is green. To regenerate the fixtures, see the generator noted in
/// faBolus-internal/REMEDIATION.md (C-01).
final class BolusMathParityTests: XCTestCase {

    private struct Fixture: Decodable {
        let carbs: Double?
        let bg: Int?
        let cr: Double
        let isf: Int
        let tgt: Int
        let iob: Double
        let u: Double
    }

    private func loadFixtures() throws -> [Fixture] {
        guard let url = Bundle.module.url(forResource: "bolus_oracle_fixtures", withExtension: "jsonl") else {
            XCTFail("bolus_oracle_fixtures.jsonl missing from test bundle resources"); return []
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return try dec.decode(Fixture.self, from: Data(trimmed.utf8))
        }
    }

    func testParityAgainstRealOracle() throws {
        let fixtures = try loadFixtures()
        XCTAssertGreaterThan(fixtures.count, 400, "expected the full oracle fixture grid")
        var mismatches: [String] = []
        for f in fixtures {
            let profile = BolusMath.Profile(carbRatioGramsPerUnit: f.cr, isfMgdlPerUnit: f.isf,
                                            targetBgMgdl: f.tgt, iobUnits: f.iob)
            let got = BolusMath.recommendedUnits(carbsGrams: f.carbs, bgMgdl: f.bg, profile: profile)
            if abs(got - f.u) > 0.00001 {
                mismatches.append("carbs=\(String(describing: f.carbs)) bg=\(String(describing: f.bg)) "
                    + "cr=\(f.cr) isf=\(f.isf) tgt=\(f.tgt) iob=\(f.iob): oracle=\(f.u) got=\(got)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "\(mismatches.count)/\(fixtures.count) diverged from the oracle:\n"
                      + mismatches.prefix(20).joined(separator: "\n"))
    }

    /// The audit C-01 headline case, asserted explicitly so a regression names itself.
    func testHeadlineBelowTargetCase() {
        // 30 g, carb ratio 10 g/U, BG 70, target 110, ISF 40, IOB 1 U.
        // Oracle = max over branches → 3 + (-1) + (-1) = 1.0 U. The old faBolus code gave 3.0 U.
        let p = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40, targetBgMgdl: 110, iobUnits: 1)
        XCTAssertEqual(BolusMath.recommendedUnits(carbsGrams: 30, bgMgdl: 70, profile: p), 1.0, accuracy: 0.0001)
    }

    /// A sanity failure (ISF ≤ 0 with a BG present) yields 0 units and is flagged, even with valid carbs.
    func testSanityFailureFlagged() {
        let p = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 0, targetBgMgdl: 110, iobUnits: 0)
        let r = BolusMath.estimate(carbsGrams: 30, bgMgdl: 150, profile: p)
        XCTAssertTrue(r.sanityFailed)
        XCTAssertEqual(r.totalUnits, 0)
    }
}
