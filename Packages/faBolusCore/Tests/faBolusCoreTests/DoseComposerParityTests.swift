import Foundation
import Testing

@testable import faBolusCore

/// Every oracle fixture through the composer's remote path: a remote that estimates with the shared
/// calculator, rounding down to the pump's step, is accepted at exactly that dose. The watch's calculator
/// runs the same file, so the two can't drift apart.
@Suite struct DoseComposerParityTests {
    typealias F = DoseFixtures

    private struct Fixture: Decodable {
        let carbs: Double?
        let bg: Int?
        let cr: Double
        let isf: Int
        let tgt: Int
        let iob: Double
        let u: Double
    }

    private func fixtures() throws -> [Fixture] {
        let url = try #require(Bundle.module.url(forResource: "bolus_oracle_fixtures", withExtension: "jsonl"))
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try decoder.decode(Fixture.self, from: Data($0.utf8))
        }
    }

    @Test func everyFixtureComposesAtTheRoundedOracleDose() throws {
        let rows = try fixtures()
        #expect(rows.count == 563)
        var checked = 0
        for row in rows {
            let settings = BolusCalculatorSettings(
                carbRatio: row.cr, correctionFactor: row.isf, targetMgdl: row.tgt, maxBolusUnits: 1000)
            // Settings the pump couldn't report aren't a dose input at all.
            guard settings.isUsable else { continue }
            checked += 1
            var pump = F.pump(glucose: row.bg)
            pump.bolusCalculator = F.observed(settings, age: 1)
            pump.insulinOnBoard = F.observed(row.iob, age: 1)
            let expected = BolusVolume.roundedDown(row.u)
            let request = F.remote(
                .calculator(carbsGrams: row.carbs ?? 0, estimateUnits: expected), glucose: row.bg)
            let decision = DoseComposer.composeRemote(request, ledger: .init(), context: F.context(pump: pump))
            let label =
                "carbs=\(String(describing: row.carbs)) bg=\(String(describing: row.bg)) cr=\(row.cr) "
                + "isf=\(row.isf) tgt=\(row.tgt) iob=\(row.iob) oracle=\(row.u)"
            if row.bg != nil && !(40...400).contains(row.tgt) {
                #expect(decision.refusal == .pumpSettingsUnusable, "\(label)")
            } else if expected == 0 {
                #expect(decision.refusal == .nothingToDeliver, "\(label)")
            } else {
                #expect(decision.dose?.units == expected, "\(label)")
            }
        }
        #expect(checked > 400)
    }
}

/// What the bolus screen shows.
@Suite struct DoseRecommendationTests {
    typealias F = DoseFixtures

    @Test func verifiedInputsRecommendTheRoundedDose() {
        let rec = DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 180, context: F.context())
        #expect(rec.units == 7.25)
        #expect(rec.inputs.isVerified)
        #expect(rec.displaysNumericDose)
    }

    /// Before the pump reports its settings and IOB, no number is shown: there is nothing real to size a
    /// dose from.
    @Test func noNumberBeforeThePumpReports() {
        for missing in [PumpState.Reading.bolusCalculator, .insulinOnBoard] {
            var pump = F.pump()
            if missing == .bolusCalculator { pump.bolusCalculator = nil } else { pump.insulinOnBoard = nil }
            let rec = DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 180, context: F.context(pump: pump))
            #expect(!rec.displaysNumericDose)
            #expect(rec.units == 0)
        }
    }

    /// Real but stale settings still come from the pump, so their number shows, marked unverified.
    @Test func staleButRealInputsDisplayUnverified() {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(F.settings, age: 3600)
        let rec = DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 180, context: F.context(pump: pump))
        #expect(rec.displaysNumericDose)
        #expect(!rec.inputs.settingsVerified)
        #expect(rec.inputs.insulinOnBoardVerified)
        #expect(rec.units == 7.25)
    }

    /// The calculator ignores an implausible glucose, so the screen is told rather than shown a number
    /// that looks like a correction.
    @Test func implausibleGlucoseIsFlagged() {
        #expect(!DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 30, context: F.context()).glucoseIsPlausible)
        #expect(DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 180, context: F.context()).glucoseIsPlausible)
        #expect(DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: nil, context: F.context()).glucoseIsPlausible)
    }

    /// When the two IOB readings disagree, the dose is sized from the larger, so it never subtracts less
    /// insulin than either implies.
    @Test func disagreeingIOBSizesFromTheLarger() {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(
            BolusCalculatorSettings(
                carbRatio: 10, correctionFactor: 40, targetMgdl: 110, maxBolusUnits: 25, insulinOnBoardUnits: 1.5),
            age: 2)
        let rec = DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 180, context: F.context(pump: pump))
        #expect(rec.inputs.insulinOnBoardReadingsDisagree)
        #expect(!rec.inputs.insulinOnBoardVerified)
        #expect(rec.units == 6.25)  // 6.00 + 1.75 − 1.50
    }
}

/// The pump's step: a calculated dose rounds down, never up.
@Suite struct BolusVolumeTests {
    @Test func roundsDownToTheStep() {
        #expect(BolusVolume.roundedDown(2.37) == 2.35)
        #expect(BolusVolume.roundedDown(2.39) == 2.35)
        #expect(BolusVolume.roundedDown(0.04) == 0)
        #expect(BolusVolume.roundedDown(25) == 25)
    }

    /// A value on a step stays on it, even when binary error puts it a hair below.
    @Test func valuesOnAStepStay() {
        #expect(BolusVolume.roundedDown(2.3) == 2.3)
        #expect(BolusVolume.roundedDown(0.1 + 0.2) == 0.3)
        #expect(BolusVolume.roundedDown(2.3 - 1e-12) == 2.3)
        for k in 0...500 {
            let units = Double(k) / 20
            #expect(BolusVolume.roundedDown(units) == units)
        }
    }

    @Test func nonNumbersRoundToZero() {
        for bad in [Double.nan, .infinity, -.infinity, -1] {
            #expect(BolusVolume.roundedDown(bad) == 0)
        }
    }
}

/// Ported from the old app's `SentAtStampTests`: a remote bolus stamped with its send time is accepted
/// while fresh, and the same message arriving past the freshness limit is refused.
@Suite struct SentAtStampTests {
    typealias F = DoseFixtures

    private func command(sentAt: Date) -> RemoteCommand {
        RemoteCommand(kind: .bolusRequest, requestId: "r1", sentAt: Int(sentAt.timeIntervalSince1970), units: 2)
    }

    private func compose(_ command: RemoteCommand, now: Date) throws -> RemoteDoseDecision {
        let request = try #require(RemoteDoseRequest(v1: command, peerId: "garmin", surface: .garmin))
        return DoseComposer.composeRemote(request, ledger: .init(), context: F.context(now: now))
    }

    @Test func aJustSentBolusIsAccepted() throws {
        let cmd = command(sentAt: F.now)
        #expect(!RemoteCommandFreshness.isStale(cmd, now: F.now))
        #expect(try compose(cmd, now: F.now).dose?.units == 2)
    }

    @Test func theSameBolusGoneStaleIsRefused() throws {
        let cmd = command(sentAt: F.now.addingTimeInterval(-RemoteCommandFreshness.maxAgeSec - 10))
        #expect(RemoteCommandFreshness.isStale(cmd, now: F.now))
        #expect(try compose(cmd, now: F.now).refusal == .requestTooOld)
    }

    @Test func aBolusWithNoStampIsRefused() throws {
        var cmd = command(sentAt: F.now)
        cmd.sentAt = nil
        #expect(try compose(cmd, now: F.now).refusal == .requestTooOld)
    }
}
