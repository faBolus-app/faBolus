import Testing
import Foundation
@testable import faBolusCore

/// P16 — S7: the pump-disconnect escalation ladder (pure schedule). Pins the invariants the app wiring
/// depends on: the step list is ordered with strictly-increasing positive delays, ids are unique and
/// stable, every body carries the explicit "use the pump's own buttons" instruction, and the ladder is
/// CAPPED (finite — a safety re-notification must never nag forever).
@Suite struct DisconnectEscalationTests {

    @Test func ladderIsFiniteAndNonEmpty() {
        // Capped: a small, bounded number of steps (no infinite nag). Non-empty so S7 actually escalates.
        #expect(!DisconnectEscalation.steps.isEmpty)
        #expect(DisconnectEscalation.steps.count <= 5)
    }

    @Test func delaysArePositiveAndStrictlyIncreasing() {
        let delays = DisconnectEscalation.steps.map(\.afterSeconds)
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(delays == delays.sorted())
        // Strictly increasing (no two steps fire at the same elapsed time).
        for (a, b) in zip(delays, delays.dropFirst()) { #expect(b > a) }
    }

    @Test func idsAreUnique() {
        let ids = DisconnectEscalation.steps.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(DisconnectEscalation.stepIds == ids)
    }

    @Test func everyBodyCarriesThePumpButtonsInstruction() {
        for step in DisconnectEscalation.steps {
            #expect(
                step.body.contains(DisconnectEscalation.pumpButtonsInstruction),
                "step \(step.id) must tell the user to use the pump's own buttons")
            #expect(!step.title.isEmpty)
        }
        // The shared instruction actually names the pump's buttons (guards against a copy edit that
        // silently drops the redirect this whole feature exists to deliver).
        #expect(DisconnectEscalation.pumpButtonsInstruction.lowercased().contains("pump's own buttons"))
    }
}
