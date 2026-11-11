import Foundation
import Testing

@testable import faBolusCore

/// The carb part a composed dose carries, so the pump can be told how much was for food and how much was
/// a correction, as Tandem's app tells it. Only a dose that is exactly the calculator's own has one.
@Suite struct DoseCarbPartTests {
    typealias F = DoseFixtures

    /// 60 g at 10 g/U is 6.00 U of the 7.25 U dose; the rest is the correction net of IOB.
    @Test func aRemoteCalculatorDoseCarriesItsCarbPart() throws {
        let dose = try #require(
            DoseComposer.composeRemote(F.remote(F.carbs(60, estimate: 7.25)), ledger: .init(), context: F.context())
                .dose)
        #expect(dose.units == 7.25)
        #expect(dose.calculatorCarbUnits == 6.0)
    }

    @Test func aPhoneCalculatorDoseCarriesItsCarbPart() throws {
        let dose = try #require(DoseComposer.composePhoneCorrecting(F.phone(F.cgmDose()), context: F.context()).dose)
        #expect(dose.calculatorCarbUnits == 6.0)
    }

    /// The user kept their own number over the calculator's: the dose isn't the calculator's, so it is
    /// sent as all food.
    @Test func aDoseChangedFromTheCalculatorsHasNoCarbPart() throws {
        let entry = F.phone(F.cgmDose(entered: 6.5))
        let dose = try #require(DoseComposer.composePhoneCorrecting(entry, context: F.context()).dose)
        #expect(dose.units == 6.5)
        #expect(dose.calculatorCarbUnits == nil)
    }

    @Test func aDoseEnteredInUnitsHasNoCarbPart() throws {
        let dose = try #require(DoseComposer.composePhoneCorrecting(F.phone(.units(2)), context: F.context()).dose)
        #expect(dose.calculatorCarbUnits == nil)
        let remote = try #require(
            DoseComposer.composeRemote(F.remote(.units(2)), ledger: .init(), context: F.context()).dose)
        #expect(remote.calculatorCarbUnits == nil)
    }

    /// A correction with no carbs has nothing for food.
    @Test func aCorrectionWithNoCarbsHasNoCarbPart() throws {
        let dose = try #require(
            DoseComposer.composeRemote(F.remote(F.carbs(0, estimate: 1.25)), ledger: .init(), context: F.context())
                .dose)
        #expect(dose.request.carbsGrams == 0)
        #expect(dose.calculatorCarbUnits == nil)
    }
}

/// The pump's clock at acceptance is kept with the entry, and a ledger saved before it existed still loads.
@Suite struct LedgerAcceptanceClockTests {
    @Test func theAcceptanceClockIsRecordedAndSurvivesASave() throws {
        let request = DoseRequest(id: "a", origin: .phone, shape: .now(units: 1))
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(request)
        ledger.markAccepted(request.ledgerKey, bolusId: 9, pumpKey: "p", pumpClock: 512_442_842)
        let decoded = try JSONDecoder().decode(RemoteBolusLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded.entry(request.ledgerKey)?.pumpClockAtAcceptance == 512_442_842)
    }

    @Test func anEntrySavedWithoutTheClockLoadsWithNone() throws {
        let request = DoseRequest(id: "a", origin: .phone, shape: .now(units: 1))
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(request)
        ledger.markAccepted(request.ledgerKey, bolusId: 9)
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "pumpClockAtAcceptance")
        json["entries"] = entries
        let decoded = try JSONDecoder().decode(
            RemoteBolusLedger.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.entry(request.ledgerKey)?.bolusId == 9)
        #expect(decoded.entry(request.ledgerKey)?.pumpClockAtAcceptance == nil)
    }
}
